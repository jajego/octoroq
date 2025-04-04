--------------------------------------------------
-- octoroq with step-by-step "full rewind"
-- + fix for rock conveyors during rewind
--------------------------------------------------

------------------------------------------
-- 1) easing, comparison, helpers
------------------------------------------
local function ease(val, target)
  return val + (target - val) * 0.5
end

function states_equal(a, b)
  -- same basic comparison as before ...
  if a.px ~= b.px or a.py ~= b.py then return false end
  if a.has_key ~= b.has_key then return false end
  if a.last_tile_x ~= b.last_tile_x then return false end
  if a.last_tile_y ~= b.last_tile_y then return false end
  if #a.rocks ~= #b.rocks then return false end
  for i=1,#a.rocks do
    local r1 = a.rocks[i]
    local r2 = b.rocks[i]
    if r1.id ~= r2.id or r1.x ~= r2.x or r1.y ~= r2.y 
       or r1.target_x ~= r2.target_x or r1.target_y ~= r2.target_y
       or r1.moving ~= r2.moving then
      return false
    end
  end
  if #a.holes ~= #b.holes then return false end
  for i=1,#a.holes do
    local h1 = a.holes[i]
    local h2 = b.holes[i]
    if h1.x ~= h2.x or h1.y ~= h2.y or h1.filled ~= h2.filled then
      return false
    end
  end
  if #a.cracks ~= #b.cracks then return false end
  for i=1,#a.cracks do
    local c1 = a.cracks[i]
    local c2 = b.cracks[i]
    if c1.x ~= c2.x or c1.y ~= c2.y or c1.broken ~= c2.broken then
      return false
    end
  end
  if a.key_collected ~= b.key_collected then return false end
  if a.fill_action ~= b.fill_action then return false end
  return true
end

local function find_entity_at(list, x, y, filter)
  for e in all(list) do
    if flr(e.x) == flr(x) and flr(e.y) == flr(y)
       and (not filter or filter(e)) then
      return e
    end
  end
end

function get_rock_at(x, y)  return find_entity_at(rocks, x, y) end
function get_hole_at(x, y)  return find_entity_at(holes, x, y) end
function get_crack_at(x, y) return find_entity_at(cracks, x, y, function(e) return not e.broken end) end

function any_rock_moving()
  for r in all(rocks) do
    if r.moving then return true end
  end
  return false
end

function draw_sprite(id, x, y, zoom)
  zoom = zoom or 1
  if zoom > 1 then
    local sx = (id % 16) * 8
    local sy = flr(id / 16) * 8
    sspr(sx, sy, 8, 8, x * zoom, y * zoom, 8 * zoom, 8 * zoom)
  else
    spr(id, x, y)
  end
end

------------------------------------------
-- 1a) conveyor detection + sprite
------------------------------------------
function is_conveyor(char)
  return (char == "v" or char == "^" or char == "<" or char == ">")
end

function conveyor_sprite(char)
  if char == "v" then return 192
  elseif char == ">" then return 193
  elseif char == "<" then return 194
  elseif char == "^" then return 195
  end
  return nil
end

------------------------------------------
-- 2) stable id system for rocks
------------------------------------------
next_rock_id = 0
rock_removal_positions = {}

function make_rock(x, y)
  local r = {
    id = next_rock_id,
    x = x, y = y,
    target_x = x, target_y = y,
    moving = false
  }
  next_rock_id += 1
  add(rocks, r)
  return r
end

function find_rock_by_id(rid)
  for r in all(rocks) do
    if r.id == rid then return r end
  end
  return nil
end

------------------------------------------
-- 3) rewind system (step-by-step)
------------------------------------------
history = {}
rewinding = false
rewind_snapshot = nil
rewind_move_id = nil
state_saved = false
last_action_filled = false
current_move_id = 0  -- increments once per manual user input

function clone_state()
  local s = {}
  s.px = px
  s.py = py
  s.has_key = has_key
  s.last_tile_x = last_tile_x
  s.last_tile_y = last_tile_y
  s.rocks = {}
  for i, r in ipairs(rocks) do
    s.rocks[i] = {
      id = r.id, x = r.x, y = r.y,
      target_x = r.target_x,
      target_y = r.target_y,
      moving = r.moving
    }
  end
  s.holes = {}
  for i, h in pairs(holes) do
    s.holes[i] = { x = h.x, y = h.y, filled = h.filled }
  end
  s.cracks = {}
  for i, c in pairs(cracks) do
    s.cracks[i] = { x = c.x, y = c.y, broken = c.broken }
  end
  if key then
    s.key_collected = key.collected
  end
  s.fill_action = last_action_filled
  -- tag each snapshot with current_move_id
  s.move_id = current_move_id
  return s
end

function push_snapshot()
  local new_snap = clone_state()
  if #history > 0 then
    local prev = history[#history]
    if states_equal(new_snap, prev) then
      return
    end
  end
  add(history, new_snap)
  last_action_filled = false
  -- cap at 50
  while #history > 50 do
    deli(history, 1)
  end
end

-- revert entire game state to snapshot "s"
function revert_to_snapshot(s)
  holes = {}
  for i, h_snap in pairs(s.holes) do
    add(holes, { x = h_snap.x, y = h_snap.y, filled = h_snap.filled })
  end
  cracks = {}
  for i, c_snap in pairs(s.cracks) do
    add(cracks, { x = c_snap.x, y = c_snap.y, broken = c_snap.broken })
  end
  has_key = s.has_key
  last_tile_x = s.last_tile_x
  last_tile_y = s.last_tile_y
  if key then
    key.collected = s.key_collected
  end

  -- rebuild rocks
  local keep_ids = {}
  for i, r_snap in ipairs(s.rocks) do
    keep_ids[r_snap.id] = true
  end
  for r in all(rocks) do
    if not keep_ids[r.id] then
      del(rocks, r)
    end
  end
  for i, r_snap in ipairs(s.rocks) do
    local cr = find_rock_by_id(r_snap.id)
    if not cr then
      local nr = make_rock(r_snap.x, r_snap.y)
      nr.id = r_snap.id
      nr.target_x = r_snap.x
      nr.target_y = r_snap.y
      nr.moving = true
    else
      cr.target_x = r_snap.x
      cr.target_y = r_snap.y
      cr.moving = true
    end
  end
end

------------------------------------------
-- 4) initialization + load
------------------------------------------
function _init()
  px = 64; py = 64
  target_px = px; target_py = py
  pspeed = 8
  frame = 1
  moving = false
  level = 17
  has_key = false
  fuzz_time = 0
  last_direction = nil
  last_tile_x = flr(px / 8) * 8
  last_tile_y = flr(py / 8) * 8
  forcedconveyor = false

  levels = {
    [1] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "w....h.....w...w",
      "w....h........hw",
      "w....h.w...w..hw",
      "w..r.h..rr...hkw",
      "w....h........hw",
      "w..h.h.........w",
      "w....h.........w",
      "w....h...p.....w",
      "w....h.........w",
      "w....h.........w",
      "w....w.....w...w",
      "w....h.........w",
      "w.d..h.........w",
      "wwwwwwwwwwwwwwww"
    },
    [2] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wh...hh....w...w",
      "w..h.hhw...w...w",
      "w..r.hh.rr.....w",
      "w....hh..h.....w",
      "w..h.hh.....h..w",
      "w....hhh...hkh.w",
      "w....hh.h...h..w",
      "w....hh..h.....w",
      "w....hh.p.h....w",
      "w....hhrr..h...w",
      "w....wh....wh..w",
      "w....hh......h.w",
      "w.d..hh.......hw",
      "wwwwwwwwwwwwwwww"
    },
    [3] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wkhhh..........w",
      "wwwwww.hhhhh...w",
      "w.....hr.r.rh..w",
      "w.r...h.r.r.h..w",
      "w......hhhhh...w",
      "w..............w",
      "w.h............w",
      "wwhhwwwwwwwwwwww",
      "ww..........r..w",
      "w.hhh..........w",
      "w.....r.....h..w",
      "w....rrr.......w",
      "w......p.....wdw",
      "wwwwwwwwwwwwwwww"
    },
    [4] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wrhrhrhrhrhrhhhd",
      "whrhrhrhrhrhrhrw",
      "wrhrhrhrhrhrhrhw",
      "whrhrhrhrhrhrhrw",
      "whrhr.rhr.rhrhrw",
      "wrhrhr.r.rhrhrhw",
      "whrhr.rpr.rhrhrw",
      "wrhrhrhr.rhrhrhw",
      "whrhrhrhrhrhrhrw",
      "wrhrhrhrhrhrhrhw",
      "whrhr.rhrhrhrhrw",
      "wrkrhrhrhrhrhrhw",
      "whrhrhrhrhrhrhrw",
      "wwwwwwwwwwwwwwww"
    },
    [5] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "w.rp...........w",
      "wwwwwwwww......w",
      "wdwk..hww......w",
      "whw..h.ww......w",
      "w.w.hrhww..r...w",
      "w.whrrrwwhhhhhhw",
      "w.w.hrhww......w",
      "w.wh.h.ww......w",
      "w.w.h.hww......w",
      "w.wh.h.ww......w",
      "whw.r.rww......w",
      "w.hr.r.hh......w",
      "w.h....hhr.r.r.w",
      "wwwwwwwwwwwwwwww"
    },
    [6] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "w..............w",
      "w..............w",
      "w......wwcww...w",
      "w.....w.....w..w",
      "w.....w.....w..w",
      "w.....w..p..w..w",
      "w......w.d.w...w",
      "w.......www....w",
      "w..............w",
      "wccccccccccccccw",
      "w.............cw",
      "w.r.r.r.r.r.rckw",
      "w.............cw",
      "wwwwwwwwwwwwwwww"
    },
    [7] = {
      zoom = 2,
      "wwwwwwww",
      "w....hdw",
      "wcrcrcrw",
      "wr.c.c.w",
      "w..r..hw",
      "wp...hkw",
      "wwwwwwww"
    },
    [8] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wdw....h.....h.w",
      "whrhc..h..hh.h.w",
      "wpcrhc.h..kh.h.w",
      "wwwcrhrh.h.h.h.w",
      "wllwcrhh.......w",
      "wlllwcrh.......w",
      "wlgllwcrhhchchcw",
      "wllgllwcrrrrrrrw",
      "wllllllww.r.r.cw",
      "w..............w",
      "w..............w",
      "w..............w",
      "w..............w",
      "wwwwwwwwwwwwwwww"
    },
    [9] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wp.............w",
      "w..r..rrrr..r..w",
      "w..cccccwcccc..w",
      "w..hhhwwhhwwh..w",
      "w..hcccccccch..w",
      "w..h.rcwcwwch..w",
      "w.whr.rkcwdhhw.w",
      "w..h.rcwwwwch..w",
      "w..hcccccccch..w",
      "w..hwhwhhwhhw..w",
      "w..cccccccccc..w",
      "w..r..rrrr..r..w",
      "w..............w",
      "wwwwwwwwwwwwwwww"
    },
    [10] = {
      zoom = 2,
      "wwwwwwww",
      "wkhhhhdw",
      "wwr.ccww",
      "w..rc..w",
      "w.rrrwww",
      "w.....pw",
      "wwwwwwww"
    },
    [11] = {
      zoom = 2,
      "wwwwwwww",
      "wglglglw",
      "wlglglgw",
      "wp.bk.dw",
      "wglglglw",
      "wlglglgw",
      "wwwwwwww"
    },
    [12] = {
        "wwwwwwwwwwwwwwww",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhdhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "w.........>>>vww",
        "wp....r.ccwwwhdw",
        "w.......ck<<<<ww",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "wwwwwwwwwwwwwwww"
    },
    [13] = {
        "wwwwwwwwwwwwwwww",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "w^^^^^V<<<<<<hhw",
        "w^^^^^Vkcwww^r.w",
        "w<<<<<<crr.r..pw",
        "wwwwdwwcc.r.c..w",
        "whhhhhhhhcccchhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "whhhhhhhhhhhhhhw",
        "wwwwwwwwwwwwwwww"
    },
    [14] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wp.............w",
      "wwwwwwwwwwwwwr.w",
      "w.......r.r....w",
      "w...crr.r.hr..rw",
      "w....hcchh..r.vw",
      "w.r.chchchchr.vw",
      "w.r.h.w.w..c.r<w",
      "w...c.wkww.hw..w",
      "w...h.wwdwwcw..w",
      "w.r.c.hhccchw..w",
      "w...hchchchcw..w",
      "w...wwwwwwwww..w",
      "w..............w",
      "wwwwwwwwwwwwwwww"
    },
    [15] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wp.............w",
      "w.wwwwwwwwwwww.w",
      "w.cc.........w.w",
      "w.cc.r.r.....w.w",
      "w.cc.wwwwwVV.w.w",
      "w.cc.hhkhhVV.w.w",
      "w.cc.hhdhhVV.w.w",
      "w.cc.hcwwhVV.w.w",
      "w.cc.....c<V.w.w",
      "w.ccr.....<<.w.w",
      "w.cc.........w.w",
      "w.wwwwwwwwwwww.w",
      "w..............w",
      "wwwwwwwwwwwwwwww"
    },
    [16] = {
      zoom = 2,
      "wwwwwwww",
      "w.V<<<pw",
      "w.>.rVVw",
      "w..rc..w",
      "wcc<r.ww",
      "wkhhhhdw",
      "wwwwwwww"
    },
    [17] = {
      zoom = 1,
      "wwwwwwwwwwwwwwww",
      "wd.....Vr.....pw",
      "whhhhhhhhhhhhhhw",
      "whhhhhh........w",
      "whhhhhh........w",
      "w..............w",
      "ww.wwwwwwwwwwwww",
      "w..<.>.........w",
      "w...c>....c..r.w",
      "w.c..<.v...r...w",
      "w..c..<c.....k.w",
      "w..c..c....r...w",
      "w..c..vc...r...w",
      "w..w^^.........w",
      "wwwwwwwwwwwwwwww"
    },
  }
  load_level(level)
end

function load_level(lvl)
  if lvl > #levels then lvl = 1 end
  level = lvl
  map = levels[level]
  rocks, holes, cracks = {}, {}, {}
  key, door = nil, nil
  rock_removal_positions = {}
  next_rock_id = 0
  forcedconveyor = false

  local actions = {
    r = function(x, y) make_rock(x, y) end,
    h = function(x, y) add(holes, { x = x, y = y, filled = false }) end,
    c = function(x, y) add(cracks, { x = x, y = y, broken = false }) end,
    k = function(x, y) key = { x = x, y = y, collected = false } end,
    d = function(x, y) door = { x = x, y = y } end,
    p = function(x, y)
      px = x; py = y
      target_px = x; target_py = y
      last_tile_x = x; last_tile_y = y
    end
  }

  for y = 0, 15 do
    local row = map[y + 1]
    if row then
      for x = 0, 15 do
        local ch = sub(row, x + 1, x + 1)
        if actions[ch] then
          actions[ch](x * 8, y * 8)
        end
      end
    end
  end
  moving = false
  has_key = false
  last_direction = nil
  state_saved = false

  history = {}
  rewinding = false
  rewind_snapshot = nil
  rewind_move_id = nil
  last_action_filled = false
  current_move_id = 0

  push_snapshot() -- initial state
end

function collide(x, y, ignore_rocks, current_rock)
  if x < 0 or x > 120 or y < 0 or y > 120 then
    return true
  end
  local gx, gy = flr(x / 8), flr(y / 8)
  local tile = sub(map[gy + 1], gx + 1, gx + 1)

  if tile == "w" then return true end
  if tile == "l" then return true end

  if not ignore_rocks and find_entity_at(holes, x, y, function(e) return not e.filled end) then
    return true
  end

  for r in all(rocks) do
    if r ~= current_rock and flr(r.x) == flr(x) and flr(r.y) == flr(y) then
      return true
    end
  end
  return false
end

----------------------------------------------
-- 5) main update + step-by-step rewind
----------------------------------------------
function _update()
  fuzz_time += 0.01

  -- trigger rewind if pressed
  if btnp(5) and not moving and not rewinding and #history > 0 then
    rewinding = true
    rewind_move_id = history[#history].move_id
  end

  -- rewinding?
  if rewinding then
    if not moving and not any_rock_moving() and #history > 0 then
      local top = history[#history]
      if top.move_id == rewind_move_id then
        del(history, top)
        rewind_snapshot = top
        revert_to_snapshot(top)
        target_px, target_py = top.px, top.py
        moving = true
      else
        rewinding = false
        rewind_snapshot = nil
      end
    elseif not moving and not any_rock_moving() then
      rewinding = false
      rewind_snapshot = nil
    end
    do_movement_animations()
    return
  end

  -- normal (non-rewind) logic
  do_movement_animations()

  if moving or any_rock_moving() then
    return
  end

  -- additional update: check non-moving rocks on conveyors
  if not rewinding then
    for r in all(rocks) do
      if not r.moving then
        local gx, gy = flr(r.x / 8), flr(r.y / 8)
        local tile = sub(map[gy + 1], gx + 1, gx + 1)
        if is_conveyor(tile) then
          check_rock_conveyor(r)
        end
      end
    end
  end

  -- normal user input
  if forcedconveyor then
    return
  end
  local direction = nil
  local dir_btn = { left = 0, right = 1, up = 2, down = 3 }
  for d, b in pairs(dir_btn) do
    if btn(b) then direction = d end
  end
  if last_direction and btn(dir_btn[last_direction]) then
    direction = last_direction
  end
  if direction then
    if not state_saved then
      current_move_id += 1
      push_snapshot()
      state_saved = true
    end
    local dx, dy = 0, 0
    if direction == "left" then dx = -pspeed; last_direction = "left" end
    if direction == "right" then dx = pspeed; last_direction = "right" end
    if direction == "up" then dy = -pspeed; last_direction = "up" end
    if direction == "down" then dy = pspeed; last_direction = "down" end

    local nx, ny = px + dx, py + dy
    if collide(nx, ny, false, nil) then
      local r = get_rock_at(nx, ny)
      if r then
        local rx, ry = r.x + dx, r.y + dy
        if not collide(rx, ry, true, r) then
          -- pushing a rock
          r.target_x, r.target_y = rx, ry
          r.moving = true
          target_px, target_py = nx, ny
          moving = true
          push_snapshot()
        end
      end
    else
      -- normal walk
      target_px, target_py = nx, ny
      moving = true
      push_snapshot()
    end
    state_saved = false
  end
end

-- this function handles the actual animation 
-- for both the player and any moving rocks.
function do_movement_animations()
  -- player movement
  if moving then
    px = ease(px, target_px)
    py = ease(py, target_py)
    if abs(px - target_px) < 0.5 and abs(py - target_py) < 0.5 then
      px, py = target_px, target_py
      moving = false
      last_direction = nil

      if not rewinding then
        local cx = flr(px / 8) * 8
        local cy = flr(py / 8) * 8
        if cx ~= last_tile_x or cy ~= last_tile_y then
          local prev_crack = get_crack_at(last_tile_x, last_tile_y)
          if prev_crack then
            prev_crack.broken = true
            add(holes, { x = prev_crack.x, y = prev_crack.y, filled = false })
            del(cracks, prev_crack)
          end
          last_tile_x, last_tile_y = cx, cy
        end

        -- pick up key?
        if key and not key.collected and flr(px) == flr(key.x) and flr(py) == flr(key.y) then
          has_key = true
          key.collected = true
        end

        -- check door
        if door and flr(px) == flr(door.x) and flr(py) == flr(door.y) and has_key then
          history = {}
          rewinding = false
          rewind_snapshot = nil
          state_saved = false
          last_action_filled = false
          load_level(level + 1)
          return
        end

        -- belts
        check_conveyor_chain_player()
      end
    end
  end

  -- rock movement
  for r in all(rocks) do
    if r.moving then
      r.x = ease(r.x, r.target_x)
      r.y = ease(r.y, r.target_y)
      if abs(r.x - r.target_x) < 0.5 and abs(r.y - r.target_y) < 0.5 then
        r.x, r.y = r.target_x, r.target_y
        r.moving = false
        -- check crack => hole => fill
        local cr = get_crack_at(r.x, r.y)
        if cr and not cr.broken then
          cr.broken = true
          add(holes, { x = cr.x, y = cr.y, filled = true })
          del(cracks, cr)
          rock_removal_positions[r.id] = { x = r.x, y = r.y }
          del(rocks, r)
          last_action_filled = true
        else
          local h = get_hole_at(r.x, r.y)
          if h and not h.filled then
            h.filled = true
            rock_removal_positions[r.id] = { x = r.x, y = r.y }
            del(rocks, r)
            last_action_filled = true
          else
            -- >>> only run conveyor logic if not rewinding <<<
            if not rewinding then
              check_rock_conveyor(r)
            end
          end
        end
      end
    end
  end
end

---------------------------------------
-- player conveyor check
---------------------------------------
function check_conveyor_chain_player()
  forcedconveyor = false
  while true do
    local gx, gy = flr(px/8), flr(py/8)
    local tile = sub(map[gy+1], gx+1, gx+1)
    if is_conveyor(tile) then
      forcedconveyor = true
      local dx, dy = 0, 0
      if tile == "v" then 
        dy = 8 
      elseif tile == "^" then 
        dy = -8 
      elseif tile == ">" then 
        dx = 8 
      elseif tile == "<" then 
        dx = -8 
      end
      local nx, ny = px + dx, py + dy
      
      -- If a rock occupies the target tile, try to push it concurrently:
      local blocking_rock = get_rock_at(nx, ny)
      if blocking_rock then
        local new_rx = blocking_rock.x + dx
        local new_ry = blocking_rock.y + dy
        if not collide(new_rx, new_ry, true, blocking_rock) then
          push_snapshot()
          blocking_rock.target_x, blocking_rock.target_y = new_rx, new_ry
          blocking_rock.moving = true
        else
          forcedconveyor = false
          return
        end
      elseif collide(nx, ny, false, nil) then
        forcedconveyor = false
        return
      end
      
      push_snapshot()
      target_px, target_py = nx, ny
      moving = true
      return  -- do one tile step and let _update() animate
    else
      forcedconveyor = false
      return
    end
  end
end  

---------------------------------------
-- rock conveyor check
---------------------------------------
function check_rock_conveyor(r)
  -- Only proceed if r is on a conveyor tile.
  local gx, gy = flr(r.x/8), flr(r.y/8)
  local tile = sub(map[gy+1], gx+1, gx+1)
  if not is_conveyor(tile) then return end
  
  -- Determine movement delta from the conveyor tile.
  local dx, dy = 0, 0
  if tile == "v" then 
    dy = 8 
  elseif tile == "^" then 
    dy = -8 
  elseif tile == ">" then 
    dx = 8 
  elseif tile == "<" then 
    dx = -8 
  end
  
  local nx, ny = r.x + dx, r.y + dy  -- r's proposed new pixel position
  
  -- Compute the target tile for r.
  local rock_target_tile_x = flr(nx/8)
  local rock_target_tile_y = flr(ny/8)
  
  -- First: if the player occupies the target tile, try to push the player.
  local player_tile_x = moving and flr(target_px/8) or flr(px/8)
  local player_tile_y = moving and flr(target_py/8) or flr(py/8)
  if rock_target_tile_x == player_tile_x and rock_target_tile_y == player_tile_y then
    local p_nx = (player_tile_x + dx/8) * 8
    local p_ny = (player_tile_y + dy/8) * 8
    if not collide(p_nx, p_ny, false, nil) then
      push_snapshot()
      target_px, target_py = p_nx, p_ny
      moving = true
    else
      return
    end
  end
  
  -- Next: check if another rock occupies the target tile.
  local blocking_rock = get_rock_at(nx, ny)
  if blocking_rock and blocking_rock ~= r then
    -- Calculate the blocking rock's next pixel position.
    local new_br_x = blocking_rock.x + dx
    local new_br_y = blocking_rock.y + dy
    if not collide(new_br_x, new_br_y, true, blocking_rock) then
      -- Initiate both moves in the same update cycle:
      push_snapshot()
      blocking_rock.target_x, blocking_rock.target_y = new_br_x, new_br_y
      blocking_rock.moving = true
      push_snapshot()
      r.target_x, r.target_y = nx, ny
      r.moving = true
    else
      return
    end
  else
    -- If no blocking rock (or it's not there), and no other collision:
    if collide(nx, ny, true, r) then return end
    push_snapshot()
    r.target_x, r.target_y = nx, ny
    r.moving = true
  end
end
 


---------------------------------------
-- drawing
---------------------------------------
function _draw()
  cls()
  local z = map.zoom or 1

  for y = 0, 15 do
    local row = map[y + 1]
    for x = 0, 15 do
      local char = sub(row, x + 1, x + 1)
      local sx, sy = x * 8, y * 8
      if char == "." then
        draw_sprite(((y % 2 == 0) == (x % 2 == 0)) and 83 or 84, sx, sy, z)
      elseif char == "w" then
        draw_sprite((x % 2 == 0 and y % 5 == 0) and (y == 0 and 70 or 69) or 64, sx, sy, z)
      elseif char == "l" then
        draw_sprite(85, sx, sy, z)
      elseif char == "g" then
        draw_sprite(36, sx, sy, z)
      elseif char == "b" then
        draw_sprite(51, sx, sy, z)
      elseif char == "c" then
        if get_crack_at(sx, sy) then
          draw_sprite(66, sx, sy, z)
        end
      else
        local csp = conveyor_sprite(char)
        if csp then
          draw_sprite(csp, sx, sy, z)
        end
      end
    end
  end

  for h in all(holes) do
    draw_sprite(h.filled and 71 or 68, h.x, h.y, z)
  end

  if key and not key.collected then
    draw_sprite(128, key.x, key.y, z)
  end
  if door then
      if has_key then
          draw_sprite(99, door.x, door.y, z)
      else
          draw_sprite(97, door.x, door.y, z)
      end
  end

  for r in all(rocks) do
    local fx = r.x + cos(fuzz_time + r.x * 0.1) * 0.15
    local fy = r.y + cos(fuzz_time + r.y * 0.1) * 0.15
    if r.moving then
      fx, fy = r.x, r.y
    end
    draw_sprite(65, fx, fy, z)
  end

  draw_sprite(frame, px, py, z)

  if level > 9 then
    print("level " .. level, 96, 122, 7)
  else
    print("level 0" .. level, 96, 122, 7)
  end
  print("octoroq", 0, 122, 122)
end
