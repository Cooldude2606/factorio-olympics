local Token = require 'utils.token'
local Task = require 'utils.task'
local Event = require 'utils.event'
local Global = require 'utils.global'
local gen = require 'utils.map_gen.generate'

--- Expcore
local Gui = require 'expcore.gui'
local Roles = require 'expcore.roles' --- @dep expcore.roles
local Commands = require 'expcore.commands'
require 'config.expcore.command_runtime_disable' --required to load before running the script

--- Locals
local WaitingGui = require 'modules.gui.mini_game_waiting'
local LoadingGui = require 'modules.gui.mini_game_loading'
local Mini_games = {
    _prototype = {},
    mini_games = {},
    events = {
        on_participant_added = script.generate_event_name(),
        on_participant_joined = script.generate_event_name(),
        on_participant_left = script.generate_event_name(),
        on_participant_removed = script.generate_event_name()
    }
}

--- Globals
local participants = {}
local primitives = { state = 'Closed' }
local vars = {
    is_lobby = false,
    server_address = ""
}

gen.init{}
gen.register()

global.servers = {}
--[[
global.servers= {
    lobby =  "127.0.0.1:12345"
}
--]]

--- Register the global variables
Global.register({
    participants = participants,
    primitives = primitives,
    vars = vars,
},function(tbl)
    participants = tbl.participants
    primitives = tbl.primitives
    vars = tbl.vars
end)

--- Used with xpcall
local function internal_error(error_message)
    game.print("Their is an error please contact the admins, error: "..error_message)
    log(debug.traceback(error_message))
end

----- Defining Mini games -----

--- Create a new instance of a mini game, the name must be unique
function Mini_games.new_game(name)
    local mini_game = {
        name        = name,
        events      = {},
        on_nth_tick = {},
        commands    = {},
        core_events = {},
        options      = 0,
    }

    Mini_games.mini_games[name] = mini_game
    return setmetatable(mini_game, { __index = Mini_games._prototype })
end

--- Add an event handler to this mini game, these handlers will be toggled on and off automatically
function Mini_games._prototype:add_event(event_name, func)
    local handler = Token.register(func)
    self.events[#self.events+1] = {event_name, handler}
end

--- Add an on nth tick handler to this mini game, these handlers will be toggled on and off automatically
function Mini_games._prototype:add_nth_tick(tick, func)
    local handler = Token.register(func)
    self.on_nth_tick[#self.on_nth_tick+1] = {tick, handler}
end

--- Set all the core events at once, normally all four are used so this can help same some lines
function Mini_games._prototype:set_core_events(on_init, on_start, on_stop, on_close)
    self.core_events = {
        on_init  = on_init,
        on_start = on_start,
        on_stop  = on_stop,
        on_close = on_close
    }
end

--- Add an on init handler to this mini game, this first code to be called by the mini game core, use to init variables and create forces and surfaces
function Mini_games._prototype:on_init(handler)
    self.core_events.on_init = handler
end

--- Add an on start handler to this mini game, called once all participants are added and ready condition is met
function Mini_games._prototype:on_start(handler)
    self.core_events.on_start = handler
end

--- Add an on stop handler to this mini game, called to stop the game, should return the data you want to save to file
function Mini_games._prototype:on_stop(handler)
    self.core_events.on_stop = handler
end

--- Add an on close handler to this mini game, this is the last code to be called by the mini game core, use to clean up used variables and removes forces and surfaces
function Mini_games._prototype:on_close(handler)
    self.core_events.on_close = handler
end

--- Add an to the allowed number of options for this mini game, used to tell /start how many params to accept
function Mini_games._prototype:add_option(amount)
    self.options = self.options + amount
end

--- Add an to the allowed number of options for this mini game, will teleport all players to 0 0 on start, if shape is given this is for redmew map gen
function Mini_games._prototype:add_surface(surface_name, shape)
    self.surface_name = surface_name
    if type(shape) == 'string' then shape = require(shape) end
    if shape then gen.add_surface(surface_name, shape) end
end

--- Add a callback to check if the mini game is ready to start, if not used game starts after init, common example is to check map gen is done
function Mini_games._prototype:set_ready_condition(callback, hide_load_gui)
    self.ready_condition = callback
    self.hide_load_gui = hide_load_gui
end

--- Add a callback to check if a player should be added as a participant, if not used participants selected randomly, callback also used to clean up its self
function Mini_games._prototype:set_participant_selector(callback, hide_wait_gui)
    self.participant_selector = callback
    self.hide_wait_gui = hide_wait_gui
end

--- Add a gui element to be used in the vote gui, this gui element will be similar to /start with the callback being used to read the values
function Mini_games._prototype:set_gui(gui_element, gui_callback)
    self.gui = gui_element
    self.gui_callback = gui_callback
end

--- Add a command that can only be used in this mini game, this will automatically enable and disable commands that are linked to this mini game
function Mini_games._prototype:add_command(command_name)
    self.commands[#self.commands + 1] = command_name
    Commands.disable(command_name)
end

----- Public Variables -----

--- Get the currently game, returns the mini game object, mostly used internally
function Mini_games.get_current_game()
    return Mini_games.mini_games[primitives.current_game]
end

--- Get the currently running game, gets the name of the current game that is running, will be nil if loading or closing
function Mini_games.get_running_game()
    if primitives.state ~= 'Starting' and primitives.state ~= 'Started' then return end
    return primitives.current_game
end

--- Get the current state of the mini game server, get the current state of the mini game system
function Mini_games.get_current_state()
    return primitives.state
end

--- Get the start time for the running game, get the start tick for the current mini game, during loading this is the time when loading started
function Mini_games.get_start_time()
    return primitives.start_tick
end

----- Participants -----

--- Internal, Raise a mini game event, this is used for all participant events
local function raise_event(name, player)
    script.raise_event(Mini_games.events[name], {
        name = Mini_games.events[name],
        player_index = player.index,
        tick = game.tick
    })
end

--- Set the number of required participants, call during on_init to set the amount of required participants, controls when the wait screen is shown
function Mini_games.set_participant_requirement(amount)
    primitives.participant_requirement = amount
end

--- Get all the participants in a game, this should be used rather than force.players or game.connected_players since this excludes spectators
function Mini_games.get_participants()
    return participants
end

--- Check if a player is a participant, searches the participants list for this player, returns true if found
function Mini_games.player_is_participant(player)
    for _, nextPlayer in ipairs(participants) do
        if nextPlayer == player then return true end
    end
    return false
end

--- Add a participant to a game, only callable before on_start, will return false if game has started and the player is not an active participant
local check_participant_count
function Mini_games.add_participant(player)
    if Mini_games.player_is_participant(player) then return true end
    if primitives.state == 'Started' then return false end
    if not player.connected then return false end

    participants[#participants+1] = player
    raise_event('on_participant_added', player)
    check_participant_count()
    return true
end

--- Remove a participant from a game, advised to be called during on_participant_left, has no effect if player is not an active participant
function Mini_games.remove_participant(player)
    for index, nextPlayer in ipairs(participants) do
        if nextPlayer == player then
            participants[index] = participants[#participants]
            participants[#participants] = nil
            raise_event('on_participant_removed', player)
            Mini_games.respawn_spectator(player)
            check_participant_count()
            return
        end
    end
end

--- Respawn a spectator, if a game is running then they are placed in a god controller
-- If there is a game closing then they will be placed in a character in the lobby
-- If there if the server is closed nothing will happen as they have already been moved to the lobby
function Mini_games.respawn_spectator(player)
    Gui.update_top_flow(player)
    if player.character then player.character.destroy() end
    if primitives.state == 'Closing' then
        local surface = game.surfaces.nauvis
        local pos = surface.find_non_colliding_position('character', {-35, 55}, 6, 1)
        player.create_character()
        player.teleport(pos, surface)
    elseif primitives.current_game then
        player.set_controller{ type = defines.controllers.god }
    end
end

----- Participant Event Logic -----

--- Used with role events to trigger add and remove participant, filters the handler to only be called with the Participant role
local function role_event_filter(handler)
    return function(event)
        for _, role in ipairs(event.roles) do
            if role.name == 'Participant' then
                return handler(game.players[event.player_index])
            end
        end
    end
end

--- Used to decide if the wait gui should be shown to a new player
-- If there is no game, hide_wait_gui is true, or a game is started the gui is hidden
local function check_wait_screen(player)
    local mini_game = Mini_games.get_current_game()
    local started = primitives.state == 'Started' or primitives.state == 'Starting'
    if not mini_game or mini_game.hide_wait_gui or started then
        WaitingGui.hide(player)
    else
        Mini_games.show_waiting_screen(player)
    end
end

--- Used to either add a participant or pass the player to participant_selector
-- If a participant selector exists then the player is passed to it
local function check_participant_selector_join(player)
    check_wait_screen(player)
    local mini_game = Mini_games.get_current_game()
    if mini_game and mini_game.participant_selector then
        xpcall(mini_game.participant_selector, internal_error, player)
    else
        Mini_games.add_participant(player)
    end
end

--- Used to either remove a participant and pass the player to participant_selector
-- If a participant selector exists then the player is passed to it
local function check_participant_selector_leave(player)
    check_wait_screen(player)
    Mini_games.remove_participant(player)
    local mini_game = Mini_games.get_current_game()
    if mini_game and mini_game.participant_selector then
        xpcall(mini_game.participant_selector, internal_error, player, true)
    end
end

--- Triggered when a player is assigned new roles, and the player has joined the server once before
-- Non participants who gain the role before game start will be added to the participants list
-- Non participants who gain the role after game start will not be added to the participants list
Event.add(Roles.events.on_role_assigned, role_event_filter(check_participant_selector_join))

--- Triggered when a player is unassigned from roles, and the player has joined the server once before
-- Participants who lose the role will be removed from the participants list, if they are on it
Event.add(Roles.events.on_role_unassigned, role_event_filter(check_participant_selector_leave))

--- Triggered when a player joins the game, will trigger on_participant_joined if there is a game running
-- Active participants who join after game start will trigger on_participant_joined
-- Inactive participants (who join before start) will be added to the participants list, or given to participant_selector
-- Non participants and Inactive participants (who join after start) will be spawned as spectator
Event.add(defines.events.on_player_joined_game, function(event)
    local player  = game.players[event.player_index]
    local started = primitives.state == 'Started'
    local participant = Roles.player_has_role(player, 'Participant')
    if participant and Mini_games.player_is_participant(player) then
        if started then raise_event('on_participant_joined', player) end
    elseif participant and not started then
        check_participant_selector_join(player)
    elseif primitives.current_game then
        Mini_games.respawn_spectator(player)
    end
end)

--- Triggered when a player leaves the game, will trigger on_participant_left if there is a game running
-- Active participants who leave after game start will be trigger on_participant_left
-- (In)Active participants who leave before game start will be removed from the participants list, and given to participant_selector
-- Non participants and Inactive participants will be moved to lobby
Event.add(defines.events.on_player_left_game, function(event)
    local player = game.players[event.player_index]
    local started = primitives.state == 'Started'
    local participant = Roles.player_has_role(player, 'Participant')
    if started and Mini_games.player_is_participant(player) then
        raise_event('on_participant_left', player)
    elseif participant and not started then
        check_participant_selector_leave(player)
    elseif primitives.current_game then
        Mini_games.respawn_spectator(player)
    end
end)

----- Starting Mini Games -----

--- Start a mini game from the lobby server, skips everything and asks players to connect to a different server
local function start_from_lobby(name, args)
    local participant_names = {}
    local server_object  = global.servers[name]
    local server_address = server_object[#server_object]
    for index, player in ipairs(participants) do
        player.connect_to_server{ address = server_address, name = name }
        participant_names[index] = player.name
    end

    local data = {
        type      = 'Started_game',
        players   = participant_names,
        name      = name,
        arguments = args,
        server    = server_address
    }

    game.write_file('mini_games/starting_game', game.table_to_json(data), false)
end

--- Start a mini game from this server, calls on_participant_joined then on_start
local start_game = Token.register(function(timeout_nonce)
    if primitives.timeout_nonce ~= timeout_nonce then return end
    local mini_game = Mini_games.get_current_game()
    primitives.start_tick = game.tick
    primitives.state = 'Starting'
    WaitingGui.remove_gui()

    -- Puts all players into spectator mode, teleports them to the surface, and call cleanup on participant selector
    local surface, selector = mini_game.surface_name, mini_game.participant_selector
    for _, player in ipairs(game.connected_players) do
        Mini_games.respawn_spectator(player)
        if surface then player.teleport({0,0}, surface) end
        if selector then
            xpcall(mini_game.participant_selector, internal_error, player, true)
        end
    end

    -- Raises on_participant_joined for all participants in the game
    for _, player in ipairs(participants) do
        raise_event('on_participant_joined', player)
    end

    -- Calls on_start core event to start the game
    local on_start = mini_game.core_events.on_start
    if on_start then
        xpcall(on_start, internal_error)
    end

    primitives.state = 'Started'
end)

--- Show the loading screen to a player, this will auto update until game is started
function Mini_games.show_loading_screen(player)
    LoadingGui.show_gui({ player_index = player.index, tick = primitives.start_tick }, primitives.current_game)
end

--- Check if the game is ready to start, used to check if the game is ready to start once per second
local check_ready
check_ready = Token.register(function()
    local mini_game = Mini_games.get_current_game()
    local success, ready = xpcall(mini_game.ready_condition, internal_error)
    if not success then
        Event.remove_removable_nth_tick(60, check_ready)
    elseif ready then
        Event.remove_removable_nth_tick(60, check_ready)
        game.print('Game starts in 10 seconds')
        primitives.timeout_nonce = math.random()
        Task.set_timeout(10, start_game, primitives.timeout_nonce)
        LoadingGui.remove_gui()
    else
        LoadingGui.update_gui(primitives.start_tick)
    end
end)

--- Show the waiting screen to a player, this will auto update until game is the required number have joined
function Mini_games.show_waiting_screen(player)
    WaitingGui.show_gui({ player_index = player.index }, primitives.current_game, #participants, primitives.participant_requirement)
end

--- Check if the game has enough participants to start, will move onto loading screen or start once the require amount is met
-- If the amount is below the required at any point between on_init and on_start the waiting screen will be shown
function check_participant_count()
    if primitives.state ~= 'Loading' then return end

    -- If the participants count is less than required, stop load checking, and update wait gui
    local mini_game = Mini_games.get_current_game()
    if not mini_game or #participants < primitives.participant_requirement then
        Event.remove_removable_nth_tick(60, check_ready)
        primitives.timeout_nonce = 0
        LoadingGui.remove_gui()
        WaitingGui.update_gui(#participants, primitives.participant_requirement)
        return
    end

    -- When requirement is met remove the gui
    WaitingGui.remove_gui(true)
    if mini_game.ready_condition then
        -- Start checking that the game is ready to start
        Event.add_removable_nth_tick(60, check_ready)
        if not mini_game.show_load_after_wait then
            for _, player in ipairs(game.connected_players) do
                Mini_games.show_loading_screen(player)
            end
        end
    else
        -- No checks needed, start game count down now
        game.print('Game starts in 10 seconds')
        primitives.timeout_nonce = math.random()
        Task.set_timeout(10, start_game, primitives.timeout_nonce)
    end
end

--- Starts a mini game if no other games are running, calls on_init then on_participant_added
function Mini_games.start_game(name, args)
    if vars.is_lobby then return start_from_lobby(name, args) end

    -- Setup and verify all args passed to the game
    args = args or {}
    local mini_game = assert(Mini_games.mini_games[name], 'This mini game does not exist')
    assert(mini_game.options == #args, 'Wrong number of arguments')
    assert(primitives.current_game == nil, 'A game is already running, please use /stop')
    primitives.participant_requirement = 0
    primitives.custom_selector = false
    primitives.current_game = name
    primitives.start_tick = game.tick
    primitives.state = 'Loading'

    -- Enable all events for this mini game
    for _, event in ipairs(mini_game.events) do
        -- event = { event_name, handler }
        Event.add_removable(unpack(event))
    end

    -- Enable all nth tick events for this mini game
    for _, event in ipairs(mini_game.on_nth_tick) do
        -- event = { tick, handler }
        Event.add_removable_nth_tick(unpack(event))
    end

    -- Enable all commands for this mini game
    for _, command_name  in ipairs(mini_game.commands) do
        Commands.enable(command_name)
    end

    -- Call the on_init core event, expects set_participant_requirement to be called
    local on_init = mini_game.core_events.on_init
    if on_init then
        xpcall(on_init, internal_error, args)
    end

    -- Get all the possible participants for this game
    local done, selector, required = {}, mini_game.participant_selector, primitives.participant_requirement
    local all_participants = Roles.get_role_by_name('Participant'):get_players(true)
    if #all_participants > 0 then table.shuffle_table(all_participants) end

    if selector then
        -- With a custom selector, first clear the participants table
        for index in ipairs(participants) do
            participants[index] = nil
        end
        -- Then call the selector on all possible participants
        for _, player in ipairs(all_participants) do
            done[player.name] = true
            xpcall(selector, internal_error, player)
        end
    else
        -- When no selector, first raise the added event for existing participants
        for _, player in ipairs(participants) do
            raise_event('on_participant_added', player)
            done[player.name] = true
        end
        -- Then attempt to fill up to the required amount
        for _, player in ipairs(all_participants) do
            if required ~= 0 and #participants >= required then break end
            if not done[player.name] then done[player.name] = Mini_games.add_participant(player) end
        end
    end

    -- Show the waiting screen to all players unless hide_wait_gui is true and player is not a spectator
    for _, player in ipairs(game.connected_players) do
        if not mini_game.hide_wait_gui or not done[player.name] then
            Mini_games.show_waiting_screen(player)
        end
    end

    -- Check if we are able to start now, if not then this will be checked again with add_participant
    check_participant_count()
end

----- Stopping Mini Games -----

--- Format an array to be the correct format for airtable
function Mini_games.format_airtable(args)
    local data = {
        type="end_game",
        Gold=args[1],
        Gold_data=args[2],
        Silver=args[3],
        Silver_data=args[4],
        Bronze=args[5],
        Bronze_data=args[6],
        server=vars.server_address,
    }
    return game.table_to_json(data)
end

--- Stop a mini game from this server, sends all players to lobby then calls on_close
local close_game = Token.register(function(timeout_nonce)
    if primitives.timeout_nonce ~= timeout_nonce then return end
    local mini_game = Mini_games.get_current_game()
    primitives.state = 'Closing'

    -- Move all players to the lobby
    for _, player in ipairs(game.connected_players) do
        Mini_games.respawn_spectator(player)
    end

    -- Call on_close core event to clean up global variables and any thing else
    local on_close = mini_game.core_events.on_close
    if on_close then
        xpcall(on_close, internal_error)
    end

    primitives.current_game = nil
    primitives.state = 'Closed'
end)

--- Stop a mini game, calls on_stop then on_participant_removed
function Mini_games.stop_game()
    local mini_game = Mini_games.get_current_game()
    local skip_timeout = primitives.state ~= 'Started'
    Event.remove_removable_nth_tick(60, check_ready)
    primitives.state = 'Stopping'

    -- Calls on_stop core event to stop the game and to get the data to write to file
    local on_stop = mini_game.core_events.on_stop
    if on_stop then
        local success, res = xpcall(on_stop, internal_error)
        if success and res then
            game.write_file('mini_games/end_game', res, false)
        end
    end

    -- Remove all participants from the game, this also places them into spectator
    for _, player in ipairs(participants) do
        Mini_games.remove_participant(player)
    end

    -- Disable all events for this mini game
    for _, event in ipairs(mini_game.events) do
        -- event = { event_name, handler }
        Event.remove_removable(unpack(event))
    end

    -- Disable all nth tick events for this mini game
    for _, event in ipairs(mini_game.on_nth_tick) do
        -- event = { tick, handler }
        Event.remove_removable_nth_tick(unpack(event))
    end

    -- Disable all commands for this mini game
    for _, command_name  in ipairs(mini_game.commands) do
        Commands.enable(command_name)
    end

    if skip_timeout then
        -- If this was called during loading, then skip the 10 second delay
        LoadingGui.remove_gui()
        WaitingGui.remove_gui()
        game.print('Game start canceled')
        primitives.timeout_nonce = math.random()
        Task.set_timeout_in_ticks(1, close_game, primitives.timeout_nonce)
    else
        -- If this was called normally wait 10 seconds before closing the game
        game.print('Returning to lobby in 10 seconds')
        primitives.timeout_nonce = math.random()
        Task.set_timeout(10, close_game, primitives.timeout_nonce)
    end

end

--- Raise an error which causes the mini game to stop
function Mini_games.error_in_game(error_game)
    game.print("An error has occurred things may be broken, error: "..error_game)
    Mini_games.stop_game()
end

----- Commands -----

--- Kicks all players from the game
Commands.new_command('kick_all', 'Kicks all players.')
:register(function(_,_)
    for _, player in ipairs(game.connected_players) do
        game.kick_player(player, "You cant stay here")
    end
end)

--- Sends all players back to the lobby server
Commands.new_command('lobby_all', 'Send everyone to the lobby server.')
:register(function(_,_)
    for _, player in ipairs(game.connected_players) do
        player.connect_to_server{ address = global.servers["lobby"], name = "lobby" }
    end
end)

--- Sets if this server is the lobby
Commands.new_command('set_lobby', 'Command to tell this server if its the lobby.')
:add_param('data',"boolean")
:register(function(_,data,_)
    vars.is_lobby = data
end)

--- Sets the address of this server
Commands.new_command('set_server_address', 'Command to set the ip:port of this server.')
:add_param('data',false)
:register(function(_,_,data)
    vars.server_address = data
end)

----- Main Gui -----

--- Used to start a mini game, will also hide the start menu from every one
local mini_game_list
local on_start_click = function (_,element,_)
    local name = element.parent.name
    local scroll_table = element.parent.parent
    local mini_game = Mini_games.mini_games[name]
    local args
    if mini_game.gui_callback then
        args = mini_game.gui_callback(scroll_table[name..'_flow'])
    end

    Mini_games.start_game(name, args)
    for _, player in ipairs(game.connected_players) do
        Gui.toggle_left_element(player, mini_game_list, false)
        Gui.update_top_flow(player)
    end
end

--- Button used to start a mini game
local start_button =
Gui.element{
    type = 'sprite-button',
    sprite = 'utility/check_mark',
    style = 'slot_button',
    tooltip = 'Start Game'
}
:on_click(on_start_click)

--- Adds the base that a mini game will add onto
local add_mini_game =
Gui.element(function(_,parent,name)
    local start_flow = parent.add{ type = 'flow', name = name }
    start_flow.style.padding = 0
    start_button(start_flow)

    parent.add{
        type    = "label",
        style   = "heading_1_label",
        caption = name
    }

    local mini_game = Mini_games.mini_games[name]
    if mini_game.gui then
        mini_game.gui(parent.add{ type = 'flow', name = name..'_flow' })
    end
end)

--- Main gui to select a mini game from
mini_game_list =
Gui.element(function(event_trigger,parent)
    local container = Gui.container(parent,event_trigger,200)

    -- Add the header
    Gui.header(container, "Start a game", "You can start the game here.")

    -- Add the scroll table
    local scroll_table = Gui.scroll_table(container, 250, 3)
    local scroll_table_style = scroll_table.style
    scroll_table_style.top_cell_padding = 3
    scroll_table_style.bottom_cell_padding = 3

    -- Add all the mini games
    for name in pairs(Mini_games.mini_games) do
        add_mini_game(scroll_table,name)
    end

    return container.parent
end)
:add_to_left_flow()

--- Add a toggle button that can be used when no game is running
Gui.left_toolbar_button('utility/check_mark', 'Select a mini game to start', mini_game_list, function(player)
    return Roles.player_allowed(player, 'gui/game_start') and (primitives.state == 'Closing' or primitives.state == 'Closed')
end)

----- Module Return -----
return Mini_games