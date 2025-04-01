------------------------------------------
-- 1) easing, comparison, and helpers
------------------------------------------
local function ease(val, target)
    return val + (target - val) * 0.5
  end
  
  function states_equal(a, b)
    if a.px         != b.px         then return false end
    if a.py         != b.py         then return false end
    if a.has_key    != b.has_key    then return false end
    if a.last_tile_x!= b.last_tile_x then return false end
    if a.last_tile_y!= b.last_tile_y then return false end
  
    if #a.rocks  != #b.rocks  then return false end
    if #a.holes  != #b.holes  then return false end
    if #a.cracks != #b.cracks then return false end
  
    if a.key_collected != b.key_collected then return false end
  
    local function find_rock_in_list(rid, list)
      for rr in all(list) do
        if rr.id == rid then return rr end
      end
      return nil
    end
    for r in all(a.rocks) do
      local match = find_rock_in_list(r.id, b.rocks)
      if not match then
        return false
      end
      if r.x != match.x or r.y != match.y then return false end
      if r.moving != match.moving then return false end
    end
  
    for i,h in ipairs(a.holes) do
      local h2 = b.holes[i]
      if not h2 then return false end
      if h.x != h2.x or h.y != h2.y or h.filled != h2.filled then
        return false
      end
    end
  
    for i,c in ipairs(a.cracks) do
      local c2 = b.cracks[i]
      if not c2 then return false end
      if c.x != c2.x or c.y != c2.y or c.broken != c2.broken then
        return false
      end
    end
    return true
  end
  
  local function find_entity_at(list, x, y, filter)
    for e in all(list) do
      if flr(e.x) == flr(x)
      and flr(e.y) == flr(y)
      and (not filter or filter(e)) then
        return e
      end
    end
  end
  
  function get_rock_at(x, y)  return find_entity_at(rocks, x, y) end
  function get_hole_at(x, y)  return find_entity_at(holes, x, y) end
  function get_crack_at(x, y)
    return find_entity_at(cracks, x, y, function(e) return not e.broken end)
  end
  
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
  -- 2) stable id system for rocks
  ------------------------------------------
  next_rock_id = 0
  rock_removal_positions = {}
  
  function make_rock(x, y)
    local r = {
      id        = next_rock_id,
      x         = x,
      y         = y,
      target_x  = x,
      target_y  = y,
      moving    = false
    }
    next_rock_id += 1
    add(rocks, r)
    return r
  end
  
  function find_rock_by_id(rid)
    for r in all(rocks) do
      if r.id == rid then
        return r
      end
    end
    return nil
  end
  
  ------------------------------------------
  -- 3) rewind system and snapshots
  ------------------------------------------
  history = {}
  rewinding = false
  rewind_snapshot = nil
  state_saved = false
  last_action_filled = false
  
  function clone_state()
    local s = {}
    s.px          = px
    s.py          = py
    s.has_key     = has_key
    s.last_tile_x = last_tile_x
    s.last_tile_y = last_tile_y
  
    s.rocks = {}
    for i,r in ipairs(rocks) do
      s.rocks[i] = {
        id        = r.id,
        x         = r.x,
        y         = r.y,
        target_x  = r.target_x,
        target_y  = r.target_y,
        moving    = r.moving
      }
    end
  
    s.holes = {}
    for i,h in pairs(holes) do
      s.holes[i] = { x=h.x, y=h.y, filled=h.filled }
    end
  
    s.cracks = {}
    for i,c in pairs(cracks) do
      s.cracks[i] = { x=c.x, y=c.y, broken=c.broken }
    end
  
    if key then
      s.key_collected = key.collected
    end
  
    s.fill_action = last_action_filled
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

     -- CAP THE HISTORY AT 50
    while #history > 50 do
        deli(history, 1)  -- remove the oldest snapshot
    end
  end
  
  ------------------------------------------
  -- 4) initialization and loading
  ------------------------------------------
  function _init()
    px = 64
    py = 64
    target_px = px
    target_py = py
    pspeed = 8
    frame = 1
    moving = false
    level = 11
    has_key = false
    fuzz_time = 0
    last_direction = nil
    last_tile_x = flr(px / 8) * 8
    last_tile_y = flr(py / 8) * 8
  
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
        "w.......ccc....w",
        "w......wwcww...w",
        "w.....w..c..w..w",
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
        zoom = 1,
        "wwwwwwwwwwwwwwww",
        "wp.............w",
        "wwwwwwwwwwwwwr.w",
        "w..............w",
        "w...crr.r.h....w",
        "w....hcchh..r..w",
        "w.r.chchchchr..w",
        "w.r.h.w.w..cw..w",
        "w...c.wkww.hw..w",
        "w...h.wwdwwcw..w",
        "w.r.c.hhccchw..w",
        "w...hchchchcw..w",
        "w...wwwwwwwww..w",
        "w..............w",
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
  
    local actions = {
      r = function(x, y) make_rock(x, y) end,
      h = function(x, y) add(holes, { x=x, y=y, filled=false }) end,
      c = function(x, y) add(cracks, { x=x, y=y, broken=false }) end,
      k = function(x, y) key = { x=x, y=y, collected=false } end,
      d = function(x, y) door= { x=x, y=y } end,
      p = function(x, y)
        px,py = x,y
        target_px, target_py = x,y
        last_tile_x,last_tile_y = x,y
      end
    }
  
    for y=0,15 do
      local row = map[y+1]
      for x=0,15 do
        local char = sub(row, x+1, x+1)
        if actions[char] then
          actions[char](x*8, y*8)
        end
      end
    end
  
    moving=false
    has_key=false
    last_direction=nil
    state_saved=false
  
    push_snapshot()
  end
  
  function collide(x, y, ignore_rocks, current_rock)
    if x<0 or x>120 or y<0 or y>120 then
      return true
    end
    local gx, gy = flr(x/8), flr(y/8)
    if sub(map[gy+1], gx+1, gx+1)=="w" then
      return true
    end
    if sub(map[gy+1], gx+1, gx+1)=="l" then
      return true
    end
    if not ignore_rocks
    and find_entity_at(holes, x, y, function(e) return not e.filled end) then
      return true
    end
  
    for r in all(rocks) do
      if r~=current_rock
      and flr(r.x)==flr(x)
      and flr(r.y)==flr(y) then
        return true
      end
    end
    return false
  end
  
  ----------------------------------------------
  -- 5) main update: normal movement + rewinding
  ----------------------------------------------
  function _update()
    fuzz_time += 0.01
  
    --------------------------------------------------
    -- rewind trigger
    --------------------------------------------------
    if btnp(5) and not moving and not rewinding and #history>0 then
      local s = history[#history]
      del(history, s)
  
      rewind_snapshot = s
      rewinding = true
  
      -- move player to old coords
      target_px, target_py = s.px, s.py
      moving = true
  
      --------------------------------------------------
      -- immediately revert holes + cracks so
      -- the hole is unfilled right away
      --------------------------------------------------
      holes = {}
      for i,h_snap in pairs(s.holes) do
        add(holes, {
          x = h_snap.x,
          y = h_snap.y,
          filled = h_snap.filled
        })
      end
      cracks = {}
      for i,c_snap in pairs(s.cracks) do
        add(cracks, {
          x = c_snap.x,
          y = c_snap.y,
          broken = c_snap.broken
        })
      end
  
      --------------------------------------------------
      -- now rebuild the rock list to match snapshot
      --------------------------------------------------
      for snap_i, snap_r in ipairs(s.rocks) do
        local current_r = find_rock_by_id(snap_r.id)
        if current_r then
          current_r.target_x = snap_r.x
          current_r.target_y = snap_r.y
          current_r.moving   = true
        else
          local removal_pos = rock_removal_positions[snap_r.id]
          local start_x = snap_r.x
          local start_y = snap_r.y
          if removal_pos then
            start_x = removal_pos.x
            start_y = removal_pos.y
          end
  
          local new_r = make_rock(start_x, start_y)
          new_r.id = snap_r.id
          new_r.target_x = snap_r.x
          new_r.target_y = snap_r.y
          new_r.moving   = true
        end
      end
  
      for r in all(rocks) do
        local found_in_snap=false
        for _,snap_r in ipairs(s.rocks) do
          if r.id==snap_r.id then
            found_in_snap=true
            break
          end
        end
        if not found_in_snap then
          del(rocks, r)
        end
      end
    end
  
    --------------------------------------------------
    -- player movement (forward or rewind)
    --------------------------------------------------
    if moving then
      px = ease(px, target_px)
      py = ease(py, target_py)
      if abs(px-target_px)<0.5 and abs(py-target_py)<0.5 then
        px,py=target_px,target_py
        moving=false
        last_direction=nil
  
        if not rewinding then
          local cx=flr(px/8)*8
          local cy=flr(py/8)*8
          if cx~=last_tile_x or cy~=last_tile_y then
            local prev_crack = get_crack_at(last_tile_x, last_tile_y)
            if prev_crack then
              prev_crack.broken = true
              add(holes, { x=prev_crack.x, y=prev_crack.y, filled=false })
              del(cracks, prev_crack)
            end
            last_tile_x,last_tile_y=cx,cy
          end
  
          if key and not key.collected
          and flr(px)==flr(key.x)
          and flr(py)==flr(key.y) then
            has_key=true
            key.collected=true
          end
  
          if door
          and flr(px)==flr(door.x)
          and flr(py)==flr(door.y)
          and has_key then
            history={}
            rewinding=false
            rewind_snapshot=nil
            state_saved=false
            last_action_filled=false
            load_level(level+1)
          end
        end
      end
    end
  
    --------------------------------------------------
    -- rock movement (forward or rewind)
    --------------------------------------------------
    for r in all(rocks) do
      if r.moving then
        r.x = ease(r.x, r.target_x)
        r.y = ease(r.y, r.target_y)
        if abs(r.x - r.target_x)<0.5 and abs(r.y - r.target_y)<0.5 then
          r.x, r.y = r.target_x, r.target_y
          r.moving = false
  
        ---------------------------------------------
-- If there's a crack here, break it
-- AND immediately fill the new hole.
---------------------------------------------
    local cr = get_crack_at(r.x, r.y)
    if cr and not cr.broken then
    -- turn crack into a hole,
    -- but fill it at the same time
    cr.broken = true
    add(holes, { x=cr.x, y=cr.y, filled=true })
    del(cracks, cr)

    -- remove the rock
    rock_removal_positions[r.id] = { x=r.x, y=r.y }
    del(rocks, r)
    last_action_filled = true

    else
    ---------------------------------------------
    -- If it's already a hole, fill as usual
    ---------------------------------------------
    local h = get_hole_at(r.x, r.y)
    if h and not h.filled then
        h.filled = true
        rock_removal_positions[r.id] = { x=r.x, y=r.y }
        del(rocks, r)
        last_action_filled = true
    end
    end

        end
      end
    end
  
    --------------------------------------------------
    -- end the rewind after everything arrives
    --------------------------------------------------
    if rewinding then
      if not moving and not any_rock_moving() then
        local s = rewind_snapshot
        has_key      = s.has_key
        last_tile_x  = s.last_tile_x
        last_tile_y  = s.last_tile_y
  
        if key then
          key.collected = s.key_collected
        end
  
        -- (this final revert won't change holes/cracks now,
        --  because we already updated them above, so it's redundant.)
        holes={}
        for i,h_snap in pairs(s.holes) do
          add(holes, { x=h_snap.x, y=h_snap.y, filled=h_snap.filled })
        end
        cracks={}
        for i,c_snap in pairs(s.cracks) do
          add(cracks,{ x=c_snap.x, y=c_snap.y, broken=c_snap.broken })
        end
  
        rewinding=false
        rewind_snapshot=nil
      end
    end
  
    --------------------------------------------------
    -- if anything is still moving, skip new input
    --------------------------------------------------
    if moving or any_rock_moving() or rewinding then
      return
    end
  
    --------------------------------------------------
    -- new movement input
    --------------------------------------------------
    local dx, dy=0,0
    local direction=nil
    local dir_btn={ left=0, right=1, up=2, down=3 }
  
    for d,b in pairs(dir_btn) do
      if btn(b) then direction=d end
    end
    if last_direction and btn(dir_btn[last_direction]) then
      direction=last_direction
    end
  
    if direction then
      if not state_saved then
        push_snapshot()
        state_saved=true
      end
  
      if direction=="left"  then dx=-pspeed; last_direction="left"  end
      if direction=="right" then dx= pspeed;  last_direction="right" end
      if direction=="up"    then dy=-pspeed; last_direction="up"    end
      if direction=="down"  then dy= pspeed;  last_direction="down"  end
  
      local new_px=px+dx
      local new_py=py+dy
  
      if collide(new_px, new_py, false) then
        local r = get_rock_at(new_px, new_py)
        if r then
          local rx, ry = r.x+dx, r.y+dy
          if not collide(rx, ry, true, r) then
            r.target_x, r.target_y=rx, ry
            r.moving=true
            target_px, target_py=new_px,new_py
            moving=true
          end
        end
      elseif not collide(new_px, new_py, false) then
        target_px, target_py=new_px,new_py
        moving=true
      end
  
      state_saved=false
    end
  end
  
  ---------------------------------------
  -- 6) drawing
  ---------------------------------------
  function _draw()
    cls()
    local zoom = map.zoom or 1
  
    for y=0,15 do
      for x=0,15 do
        local char=sub(map[y+1], x+1, x+1)
        local sx, sy=x*8, y*8
        if char=="." then
          draw_sprite(((y%2==0)==(x%2==0)) and 83 or 84, sx, sy, zoom)
        elseif char=="w" then
          draw_sprite((x%2==0 and y%5==0) and (y==0 and 70 or 69) or 64, sx, sy, zoom)
        elseif char=="l" then
            draw_sprite(85, sx, sy, zoom)
        elseif char=="g" then
            draw_sprite(36, sx, sy, zoom)
        elseif char=="b" then
            draw_sprite(51, sx, sy, zoom)
        elseif char=="c" then
          if get_crack_at(sx, sy) then
            draw_sprite(66, sx, sy, zoom)
          end
        end
      end
    end
  
    for h in all(holes) do
      draw_sprite(h.filled and 71 or 68, h.x, h.y, zoom)
    end
  
    if key and not key.collected then
      draw_sprite(128, key.x, key.y, zoom)
    end
  
    if door then
      draw_sprite(97, door.x, door.y, zoom)
    end
  
    for r in all(rocks) do
      local fx = r.x+cos(fuzz_time + r.x*0.1)*0.15
      local fy = r.y+cos(fuzz_time + r.y*0.1)*0.15
      if r.moving then
        fx, fy = r.x, r.y
      end
      draw_sprite(65, fx, fy, zoom)
    end
  
    draw_sprite(frame, px, py, zoom)
  
    print("octoroq", 0, 122, 122)
    if level > 9 then
        print("level "..level, 96, 122, 7)
    else
        print("level 0"..level, 96, 122, 7)
    end
  end
  