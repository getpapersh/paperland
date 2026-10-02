#include <plugins/PluginAPI.hpp>
#include <desktop/state/LayerState.hpp>
#include <desktop/view/LayerSurface.hpp>
#include <protocols/LayerShell.hpp>
#include <managers/input/InputManager.hpp>
#include <managers/SeatManager.hpp>
#include <devices/IKeyboard.hpp>
#include <state/WorkspaceState.hpp>
#include <desktop/Workspace.hpp>
#include <layout/space/Space.hpp>
#include <layout/algorithm/Algorithm.hpp>
#include <layout/algorithm/tiled/scrolling/ScrollingAlgorithm.hpp>
#include <config/shared/workspace/WorkspaceRuleManager.hpp>
#include <config/ConfigValue.hpp>
#include <cmath>
#include <cstdint>
#include <map>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <vector>
#include <lua.hpp>
#include <version.h>

static CHyprSignalListener buttonListener;
static uint32_t routedButton = 0;
static CBox routedGeometry;
static HANDLE pluginHandle = nullptr;
struct CardBox { double x, y, width, height; };
static std::map<int, std::vector<CardBox>> cards;

static SDispatchResult setCards(std::string args) {
    std::istringstream input(args);
    int monitor = -1, count = -1;
    if (!(input >> monitor >> count) || monitor < 0 || count < 0 || count > 512)
        return {.success = false, .error = "Invalid Paperland card count"};
    std::vector<CardBox> next;
    for (int i = 0; i < count; ++i) {
        CardBox box;
        if (!(input >> box.x >> box.y >> box.width >> box.height)
            || !std::isfinite(box.x) || !std::isfinite(box.y)
            || !std::isfinite(box.width) || !std::isfinite(box.height)
            || box.width <= 0 || box.height <= 0)
            return {.success = false, .error = "Invalid Paperland card box"};
        next.push_back(box);
    }
    std::string extra;
    if (input >> extra)
        return {.success = false, .error = "Unexpected Paperland card data"};
    cards[monitor] = std::move(next);
    return {};
}

static int luaSetCards(lua_State* state) {
    const char* args = lua_tostring(state, 1);
    const auto result = args ? setCards(args) : SDispatchResult{.success = false, .error = "Missing Paperland card data"};
    lua_pushboolean(state, result.success);
    if (!result.success) {
        lua_pushstring(state, result.error.c_str());
        return 2;
    }
    return 1;
}

static int luaEffectiveDirection(lua_State* state) {
    const auto number = lua_tonumber(state, 1);
    if (lua_type(state, 1) != LUA_TNUMBER || !std::isfinite(number) || number <= 0
        || number != std::floor(number) || number >= static_cast<double>(std::numeric_limits<WORKSPACEID>::max())) {
        lua_pushnil(state);
        return 1;
    }
    const auto workspace = State::workspaceState()->query().id(static_cast<WORKSPACEID>(number)).run();
    if (!workspace || !workspace->m_space || !workspace->m_space->algorithm()
        || !dynamic_cast<Layout::Tiled::CScrollingAlgorithm*>(workspace->m_space->algorithm()->tiledAlgo().get())) {
        lua_pushnil(state);
        return 1;
    }

    // Match Hyprland 0.56.2 CScrollingAlgorithm::getDynamicDirection: its
    // merged workspace rule overrides scrolling:direction at observation time.
    const auto rule = Config::workspaceRuleMgr()->getWorkspaceRuleFor(workspace);
    static const auto global = CConfigValue<Config::STRING>("scrolling:direction");
    if (!global.good()) {
        lua_pushnil(state);
        return 1;
    }
    std::string direction = *global;
    if (rule) {
        const auto option = rule->m_layoutopts.find("direction");
        if (option != rule->m_layoutopts.end() && !option->second.empty())
            direction = option->second;
    }
    if (direction != "right" && direction != "left" && direction != "up" && direction != "down") {
        lua_pushnil(state);
        return 1;
    }
    lua_pushstring(state, direction.c_str());
    return 1;
}

static bool cardAtPointer() {
    const auto pos = g_pInputManager->getMouseCoordsInternal();
    for (const auto& layer : Desktop::layerState()->layers()) {
        if (layer->m_namespace != "paperland-minimap" || !layer->m_mapped
            || pos.x < layer->m_geometry.x || pos.x >= layer->m_geometry.x + layer->m_geometry.w
            || pos.y < layer->m_geometry.y || pos.y >= layer->m_geometry.y + layer->m_geometry.h)
            continue;
        const auto monitorCards = cards.find(layer->monitorID());
        if (monitorCards == cards.end())
            continue;
        for (const auto& box : monitorCards->second)
            if (pos.x >= box.x && pos.x < box.x + box.width
                && pos.y >= box.y && pos.y < box.y + box.height)
                return true;
    }
    return false;
}

static bool overMinimap() {
    const auto focus = g_pSeatManager->m_state.pointerFocus.lock();
    if (!focus || !cardAtPointer())
        return false;
    for (const auto& layer : Desktop::layerState()->layers()) {
        if (layer->m_namespace != "paperland-minimap" || !layer->m_mapped)
            continue;
        const auto resource = layer->m_layerSurface.lock();
        if (resource && resource->m_surface.lock() == focus) {
            const auto pos = g_pInputManager->getMouseCoordsInternal();
            if (pos.x >= layer->m_geometry.x && pos.x < layer->m_geometry.x + layer->m_geometry.w
                && pos.y >= layer->m_geometry.y && pos.y < layer->m_geometry.y + layer->m_geometry.h) {
                routedGeometry = layer->m_geometry;
                return true;
            }
        }
    }
    return false;
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    if (std::string(__hyprland_api_get_hash()) != __hyprland_api_get_client_hash())
        throw std::runtime_error("Paperland input bridge ABI mismatch");
    pluginHandle = handle;
    HyprlandAPI::addLuaFunction(handle, "paperland", "set_cards", luaSetCards);
    HyprlandAPI::addLuaFunction(handle, "paperland", "effective_direction", luaEffectiveDirection);
    buttonListener = Event::bus()->m_events.input.mouse.button.listen(
        [](IPointer::SButtonEvent event, Event::SCallbackInfo& info) {
            if (event.button != 272)
                return;
            if (event.state == WL_POINTER_BUTTON_STATE_PRESSED) {
                routedButton = 0;
                const auto modifiers = g_pInputManager->getModsFromAllKBs();
                if (!(modifiers & (HL_MODIFIER_META | HL_MODIFIER_SHIFT)) || !cardAtPointer())
                    return;
                g_pInputManager->refocus(g_pInputManager->getMouseCoordsInternal());
                if (overMinimap())
                    routedButton = modifiers & HL_MODIFIER_SHIFT ? 275 : 276;
            }
            if (!routedButton)
                return;
            info.cancelled = true;
            if (event.state == WL_POINTER_BUTTON_STATE_RELEASED) {
                const auto pos = g_pInputManager->getMouseCoordsInternal();
                g_pSeatManager->sendPointerMotion(event.timeMs, {pos.x - routedGeometry.x, pos.y - routedGeometry.y});
            }
            g_pSeatManager->sendPointerButton(event.timeMs, routedButton, event.state);
            g_pSeatManager->sendPointerFrame();
            if (event.state == WL_POINTER_BUTTON_STATE_RELEASED)
                routedButton = 0;
        });
    return {"Paperland minimap input", "Routes Super-card gestures to the minimap", "Paperland", __hyprland_api_get_client_hash()};
}

APICALL EXPORT void PLUGIN_EXIT() {
    buttonListener.reset();
    if (pluginHandle)
        HyprlandAPI::removeLuaFunction(pluginHandle, "paperland", "set_cards");
    if (pluginHandle)
        HyprlandAPI::removeLuaFunction(pluginHandle, "paperland", "effective_direction");
    pluginHandle = nullptr;
    cards.clear();
    routedButton = 0;
}
