---------------------------
-- 0) screen / menu state
---------------------------
screen_mode      = "title"   -- title | levelselect | game | pause
menu_index       = 1         -- title‑screen highlight
level_select_idx = 1         -- level‑select highlight
pause_index      = 1         -- pause‑menu highlight
max_levels       = 30        -- total levels

---------------------------
-- 0a) native pause hooks
---------------------------
-- these items appear *after* PICO‑8’s built‑in
-- resume / reset cart / mute / music options
menuitem(1, "restart level", function()
  if screen_mode == "game" then load_level(level) end
end)
menuitem(2, "back to title", function()
  screen_mode = "title"
end)

-- optional: react when the user toggles pause
function _pause()
  -- return true to suppress the menu (not used here)
end

---------------------------
-- 1) helpers
---------------------------
function ease(v,t) return v+(t-v)*0.5 end
function b2s(b) return b and "1" or "0" end
function s2b(c) return c=="1" end

-- simple join / split
function join(list)
  local out=""
  for i=1,#list do
    if i>1 then out=out.."," end
    out=out..list[i]
  end
  return out
end

function split_csv(str)
  local t,field={}, ""
  for i=1,#str do
    local ch=sub(str,i,i)
    if ch=="," then
      add(t,field) field=""
    else
      field=field..ch
    end
  end
  add(t,field)
  return t
end

---------------------------
-- 1a) state comparison
---------------------------
function states_equal(a,b)
  if a.px~=b.px or a.py~=b.py then return false end
  if a.has_key~=b.has_key then return false end
  if a.last_tile_x~=b.last_tile_x or a.last_tile_y~=b.last_tile_y then return false end
  if #a.rocks~=#b.rocks then return false end
  for i=1,#a.rocks do
    local r1=a.rocks[i] local r2=b.rocks[i]
    if r1.id~=r2.id or r1.x~=r2.x or r1.y~=r2.y
       or r1.target_x~=r2.target_x or r1.target_y~=r2.target_y
       or r1.moving~=r2.moving then
      return false
    end
  end
  if #a.holes~=#b.holes then return false end
  for i=1,#a.holes do
    local h1=a.holes[i] local h2=b.holes[i]
    if h1.x~=h2.x or h1.y~=h2.y or h1.filled~=h2.filled then return false end
  end
  if #a.cracks~=#b.cracks then return false end
  for i=1,#a.cracks do
    local c1=a.cracks[i] local c2=b.cracks[i]
    if c1.x~=c2.x or c1.y~=c2.y or c1.broken~=c2.broken then return false end
  end
  if a.key_collected~=b.key_collected then return false end
  if a.fill_action~=b.fill_action then return false end
  return true
end

---------------------------
-- 1b) entity helpers
---------------------------
function find_entity_at(list,x,y,flt)
  for e in all(list) do
    if flr(e.x)==flr(x) and flr(e.y)==flr(y) and (not flt or flt(e)) then
      return e
    end
  end
end
function get_rock_at(x,y)  return find_entity_at(rocks,x,y) end
function get_hole_at(x,y)  return find_entity_at(holes,x,y) end
function get_crack_at(x,y) return find_entity_at(cracks,x,y,function(e) return not e.broken end) end
function any_rock_moving()
  for r in all(rocks) do if r.moving then return true end end
  return false
end
function draw_sprite(id,x,y,z)
  z=z or 1
  if z>1 then
    local sx=(id%16)*8
    local sy=flr(id/16)*8
    sspr(sx,sy,8,8,x*z,y*z,8*z,8*z)
  else
    spr(id,x,y)
  end
end

---------------------------
-- 1c) conveyors
---------------------------
function is_conveyor(c) return (c=="v" or c=="^" or c=="<" or c==">") end
function conveyor_sprite(c)
  if c=="v" then return 192
  elseif c==">" then return 193
  elseif c=="<" then return 194
  elseif c=="^" then return 195 end
end

---------------------------
-- 2) rocks with stable ids
---------------------------
next_rock_id=0
rock_removal_positions={}
function make_rock(x,y)
  local r={id=next_rock_id,x=x,y=y,target_x=x,target_y=y,moving=false}
  next_rock_id+=1
  add(rocks,r)
  return r
end
function find_rock_by_id(i)
  for r in all(rocks) do if r.id==i then return r end end
end

---------------------------
-- 3) history (100) + (de)serialization
---------------------------
history={}              -- array of serialized strings
last_snapshot_table=nil -- last full table for equality check
rewinding=false
rewind_move_id=nil
state_saved=false
last_action_filled=false
current_move_id=0

-- serialize table -> csv string
function serialize_state(s)
  local p={}
  add(p,s.px) add(p,s.py) add(p,b2s(s.has_key))
  add(p,s.last_tile_x) add(p,s.last_tile_y)
  add(p,b2s(s.key_collected)) add(p,b2s(s.fill_action))
  add(p,s.move_id)
  add(p,#s.rocks)
  for r in all(s.rocks) do
    add(p,r.id) add(p,r.x) add(p,r.y)
    add(p,r.target_x) add(p,r.target_y) add(p,b2s(r.moving))
  end
  add(p,#s.holes)
  for h in all(s.holes) do
    add(p,h.x) add(p,h.y) add(p,b2s(h.filled))
  end
  add(p,#s.cracks)
  for c in all(s.cracks) do
    add(p,c.x) add(p,c.y) add(p,b2s(c.broken))
  end
  return join(p)
end

-- deserialize csv string -> table
function deserialize_state(str)
  local a=split_csv(str)
  local i=1
  local function nxt() local v=a[i] i+=1 return v end
  local s={}
  s.px=tonum(nxt()) s.py=tonum(nxt())
  s.has_key=s2b(nxt())
  s.last_tile_x=tonum(nxt()) s.last_tile_y=tonum(nxt())
  s.key_collected=s2b(nxt())
  s.fill_action=s2b(nxt())
  s.move_id=tonum(nxt())
  local rc=tonum(nxt())
  s.rocks={}
  for r=1,rc do
    add(s.rocks,{
      id=tonum(nxt()),
      x=tonum(nxt()),y=tonum(nxt()),
      target_x=tonum(nxt()),target_y=tonum(nxt()),
      moving=s2b(nxt())
    })
  end
  local hc=tonum(nxt())
  s.holes={}
  for h=1,hc do
    add(s.holes,{x=tonum(nxt()),y=tonum(nxt()),filled=s2b(nxt())})
  end
  local cc=tonum(nxt())
  s.cracks={}
  for c=1,cc do
    add(s.cracks,{x=tonum(nxt()),y=tonum(nxt()),broken=s2b(nxt())})
  end
  return s
end

function clone_state()
  local s={
    px=px,py=py,has_key=has_key,
    last_tile_x=last_tile_x,last_tile_y=last_tile_y,
    rocks={},holes={},cracks={},
    key_collected=key and key.collected or false,
    fill_action=last_action_filled,
    move_id=current_move_id
  }
  for r in all(rocks) do
    add(s.rocks,{id=r.id,x=r.x,y=r.y,
      target_x=r.target_x,target_y=r.target_y,moving=r.moving})
  end
  for h in all(holes) do add(s.holes,{x=h.x,y=h.y,filled=h.filled}) end
  for c in all(cracks) do add(s.cracks,{x=c.x,y=c.y,broken=c.broken}) end
  return s
end

function push_snapshot()
  local new=clone_state()
  if last_snapshot_table and states_equal(new,last_snapshot_table) then return end
  add(history,serialize_state(new))
  last_snapshot_table=new
  while #history>1000 do deli(history,1) end
  last_action_filled=false
end

---------------------------
-- 4) init + level data
---------------------------

function _init()
  screen_mode="title"
  px,py=64,64 
  target_px,target_py=px,py
  pspeed=8
  frame=1
  moving=false
  level=0
  has_key=false
  fuzz_time=0
  last_direction=nil
  last_tile_x=flr(px/8)*8
  last_tile_y=flr(py/8)*8
  forcedconveyor=false
  l_music=0

  palt(0, true)

  music(0)

  cartdata("octoroq_progress")
  level_stars = {}
  level_moves = {}
  for i=1,max_levels do
    level_stars[i] = dget(i) > 0 and true or false
    level_moves[i] = dget(i + 32) > 0 and dget(i + 32) or nil
  end


  ------------------------------------
  -- levels table
  ------------------------------------
  levels={
      [0]={zoom=1,  -- HOW TO ROQ
      "................",
      ".....r>h>.......",
      "................",
      "....,...........",
      "................",
      "wwwwwwwwwwwwwwww",
      "w......ww......w",
      "wp.....rh..k..dw",
      "w......ww......w",
      "wwwwwwwwwwwwwwww",
      "................",
      "................",
      "................",
      "................",
      "................",
    },
    [1]={zoom=1,     -- THE CAVE
      "................",
      "................",
      "................",
      "................",
      "................",
      "wwwwwwwwwwwwwwww",
      "w.....rh......hw",
      "wp....rh..k..hdw",
      "w.....rh......hw",
      "wwwwwwwwwwwwwwww",
      "................",
      "................",
      "................",
      "................",
      "................",
    },
    [2]={zoom=1,   -- THE BRIDGE
"................",
"................",
"................",
"...wwwwwwwwww...",
"...wd......hw...",
"...wwwwwwwwhw...",
"...w...r...kw...",
"...w......hhw...",
"...w...r.r..w...",
"...wp.......w...",
"...wwwwwwwwww...",
"................",
"................",
"................",
},
    [3]={zoom=1,   -- GRIDLOCK
    "................",
    "................",
      "wwwwwwwwwwwwwwww",
      "wkhhh..........w",
      "wwwwww.hhhhh.w.w",
      "w.....hr.r.rh..w",
      "w.r...h.r.r.h..w",
      "w.r....hhhhh...w",
      "w..............w",
      "w.p...........dw",
      "w..............w",
      "wwwwwwwwwwwwwwww",
      "................",
      "................",},
    [4]={zoom=1,   -- HIGHS AND LOWS
      "wwwwwwwwwwwwwwww",
      "w..p...........w",
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
      "wwwwwwwwwwwwwwww"},
    [5]={zoom=1,  -- CRACKS
      "....wwwwwwww....",
      "....w...p..w....",
      "....wccccccw....",
      "....wccccccw....",
      "....wccccccw....",
      "....wccccccw....",
      "....wccckccw....",
      "....wccccccw....",
      "....wccccccw....",
      "....wccccccw....",
      "....wwrrrrww....",
      "....wwccccww....",
      "....w......w....",
      "....w.....dw....",
      "....wwwwwwww...."},
    [6]={zoom=1, -- FILLING IN
    "................",
    "................",
    "................",
    "................",
      "....wwwwwwww",
      "....w....hdw",
      "....wcrcrcrw",
      "....wr.c.c.w",
      "....w..r..hw",
      "....wp...hkw",
      "....wwwwwwww",
      "................",
      "................",
      "................",
      "................",

    },
    -- [7]={zoom=1, -- DAY AT THE LAKE
    -- "................",
    -- "................",

    --   "wwwwwwwwwwwwwwww",
    --   "wdw....h.......w",
    --   "whrhc..h..hh...w",
    --   "wp.rhc.h..kh...w",
    --   "www.rhrh.h.h...w",
    --   "wllwcrhh.......w",
    --   "wlllwcrh.......w",
    --   "wlgllwcrhhchchcw",
    --   "wllgllwcrrrrrrrw",
    --   "wllllllww.r.r.cw",
    --   "w..............w",
    --   "wwwwwwwwwwwwwwww",
    --   "................",
    --   "................",
    -- },
      [7]={zoom=1,
      "................",
      "................",
      "................",
      "wwwwwwwwwwwwwwww",
      "wlllll.......llw",
      "wlllllcccccccwww",
      "wwwwwwccc.r.chkw",
      "wp....cccrcrcwww",
      "wwwwwwccc.r.chdw",
      "wlllllcccccccwww",
      "wlllll.......llw",
      "wwwwwwwwwwwwwwww",
      "................",
      "................",
      "................",
    },
    [8]={zoom=2, -- CAVE II
      "1llllll2",
      "lkhhhhdl",
      "lwr.ccwl",
      "l..rc..l",
      "l.rrrwwl",
      "l.....pl",
      "3llllll4"},
      [9]={zoom=1, -- THIN ICE
      "wwwwwwwwwwwwwwww",
      "wpccccwcccccccw.",
      ".wcccccccwcccwcw",
      "wcccccwccccwccw.",
      ".wcccccccwcccwcw",
      "wcccccwccwcwccw.",
      ".wcccccccccccwcw",
      "wcccccwccrcwccw.",
      ".wcccccccccccwcw",
      "wcccccwccwcwccw.",
      ".wcccccccwcccwcw",
      "wcccccwccccwrcw.",
      ".wcccccccwcrcwcw",
      "wdccccwccccrckw.",
      "wwwwwwwwwwwwwwww"},
      [10]={zoom=1,
      "................",
    "................",
    "................",
    "...wwwwwwwwww...",
    "...wrhrhrhrhw...",
    "...wkrhrhrhrw...",
    "...wrhhrrhrhw...",
    "...whrhrprhrw...",
    "...wrhrhrrrhw...",
    "...whrhrhrdrw...",
    "...wrhrhrhrhw...",
    "...wwwwwwwwww...",
    "................",
    "................",
    "................",
      },
 
    -- [11]={zoom=2, -- BREAD TIME
    --   "wwwwwwww",
    --   "wglglglw",
    --   "wlglglgw",
    --   "wp.bk.dw",
    --   "wglglglw",
    --   "wlglglgw",
    --   "wwwwwwww"},
    [11]={zoom=1, -- AUTOMATIC
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
      "wwwwwwwwwwwwwwww"},
    [12]={zoom=1, -- FACTORY FLOOR
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
      "wwwwwwwwwwwwwwww"},
      [13]={zoom=1,
      "wwwwwwwwwwwwwwww",
    "wwkcchd........w",
    "w.wcchc.r....p.w",
    "w..wcrw..r.....w",
    "w...w^<...r....w",
    "wwwwwwwwwwwwwwww",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wllllllllllllllw",
    "wwwwwwwwwwwwwwww",
    },
    [14]={zoom=1, -- DOMAIN
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
      "wwwwwwwwwwwwwwww"},
    [15]={zoom=2, -- CAVE III
      "wwwwwwww",
      "w.V<<<pw",
      "w.>.rVVw",
      "w..rc..w",
      "wcc<r.ww",
      "wkhhhhdw",
      "wwwwwwww"},
    [16]={zoom=1, -- JUNKYARD
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
      "wwwwwwwwwwwwwwww"},
    [17]={
      "wwwwwwwwwwwwwwww",
      "wp.............w",
      "w.cccccccccccccw",
      "w.cw.w.w.w.w.wcw",
      "w.c.r.r.r.r.r.cw",
      "w.cw.w.w.w.w.wcw",
      "w.c.r.<.^.>.r.cw",
      "w.cw.w.wkw.w.wcw",
      "w.c.r.>.>.^.r.cw",
      "w.cw.w.w.w.w.wcw",
      "w.c.r.r.r.r.r.cw",
      "w.cw.w.w.w.w.wcw",
      "w.cccccccccccccw",
      "w.............dw",
      "wwwwwwwwwwwwwwww",
    },
    [18]={zoom=1,
    "wwwwwwwwwwwwwwww",
  "w..............w",
  "w..r........r..w",
  "w.rwr......rwr.w",
  "w..r..h.h.h.r..w",
  "w...hhhhhhhh...w",
  "w....h<^^^h....w",
  "w..hh<dwwk>hh..w",
  "w....h<vv>h....w",
  "w...hhhhhhhh...w",
  "w..r..h.h.h.r..w",
  "w.rwr......rwr.w",
  "w..r........r..w",
  "w.......p......w",
  "wwwwwwwwwwwwwwww",
    },

    [19]={zoom=2,

  "1llllll2....",
  "l<<<v<<l....",
  "lvkvr.>l....",
  "lvrw>w>l....",
  "lv>rvd>l....",
  "l>p>>>^l....",
  "3llllll4....",
  "................",
  "................",
  "................",
  "................",},
    [20]={zoom=1,
    "................",
    "....wwwwwwww....",
    "....wkcccccw....",
    "....wccccccw....",
    "..wwwrrwwrwwww..",
    "..wpw..w...w.w..",
    "..w.w..w...w.w..",
    "..w.w..w...w.w..",
    "..w..r...r...w..",
    "..w..........w..",
    "..wwwvvvvvvwww..",
    "....wvvvvv<w....",
    "....wvvvvvdw....",
    "....wwwwwwww....",
    "................",},
    [21]={zoom=1, -- OFFICE
      "wwwwwwwwwwwwwwww",
      "w...>.>..>.>...w",
      "w...<.<.r>.>...w",
      "w^^^<.<^^>.>>>ww",
      "w....r....r....w",
      "w^^^<.<^^>.>>>ww",
      "whhh>.>..<.<hwhw",
      "whkh>.>rr<.<hdhw",
      "whhh>.>.p<.<hwhw",
      "w^^^^.^^^^.>>>ww",
      "w....r....r....w",
      "w^^^>.>vv<.<>>ww",
      "w.r.<.<r.>.>.r.w",
      "w...^.^..^.<...w",
      "wwwwwwwwwwwwwwww"},
    [22]={zoom=1, -- LEARN TO WEAVE
      "wwwwwwwwwwwwwwww",
      "wv<...v.<<...r.w",
      "w.>>..v..>>..r<w",
      "w..<>..r>>>>...w",
      "w>..<>..p..<<..w",
      "w..v.<^.c..<<>.w",
      "w.vr..<>.c.<.<>w",
      "w.>...^<>..<...w",
      "wv<<<<<.<>.>...w",
      "w.....>..<>>.r.w",
      "w>....>...<>..<w",
      "w.r...>.>..<>..w",
      "wwwwh.>..cr.<>.w",
      "wdhhh.>......>^w",
      "wwwwwwwwwwwwwwww"},
      [23]={zoom=1, -- MINESHAFT
      "................",
      "................",
      "................",
      "................",
      "wwwwwwwwwwwwwwww",
      "w.......h.....kw",
      "w...rrrr>v>v.<<w",
      "w...vvc>^cw<>>^w",
      "w...c>>whr..hhhw",
      "wp.......>.^w<dw",
      "wwwwwwwwwwwwwwww",
      "................",
      "................",
      "................",
      "................",
    },
    [24]={zoom=1, -- DOMAIN II
    "wwwwwwwwwwwwwwww",
    "www..........www",
    "wpw..rcr.r>c.w.w",
    "w..>..^.....v..w",
    "w...<>>vwc.^...w",
    "w....wccccw.c..w",
    "w.r..cwhhwc..r.w",
    "w..r^chkwhc^r..w",
    "w.rvwchwdhcwvr.w",
    "w..>>^whhwc.<..w",
    "w....w>cccw....w",
    "w...v.^wv..>...w",
    "w..^.r.r.r..<..w",
    "www..........www",
    "wwwwwwwwwwwwwwww",},
    [25]={zoom=1,
      "..wwwwwwwwwwww..",
      "..w>>>>>>>vwvw..",
      "..wwp.......vw..",
      "..wcr.r.r.r.vw..",
      "..w>>>>>vwcwvw..",
      "..w^khhhvc.cvw..",
      "..w^hhhhv.rcvw..",
      "..w^hhhhvc.cvw..",
      "..w^hhhdv.rcvw..",
      "..w^w^<<<c.cvw..",
      "..w^......rcvw..",
      "..w^.crcrc.cvw..",
      "..w^ccccccccvw..",
      "..w^<<<<<<<<<w..",
      "..wwwwwwwwwwww..",},
      [26]={zoom=1,
      "wwwwwwwwwwwwwwww",
      "w......<.hhhhhdw",
      "w......rrwwwwwww",
      "w.c.c.ccccc.cckw",
      "w.............cw",
      "w.^r^^r^^r^^r^.w",
      "w..cccccc..c.ccw",
      "wcc.c.cccccccccw",
      "w......c.......w",
      "w...^r^..^r^...w",
      "w.c...ccc...cc.w",
      "w..^r^....^r^..w",
      "w..ccc.ccccccc.w",
      "w.......p......w",
      "wwwwwwwwwwwwwwww",
      },
      [27]={zoom=1, -- DOMAIN II
      "wwwwwwwwwwwwwwww",
      "w..h........h..w",
      "w.hkh......hdh.w",
      "w..h........h..w",
      "whhhhhhhhhhhhhhw",
      "w..............w",
      "w....h....h....w",
      "w...hch..hch...w",
      "w....hr..rhr...w",
      "w...cr.hh.rc...w",
      "w...rhr..rh....w",
      "w...hch..hch...w",
      "w....h....h....w",
      "w......p.......w",
      "wwwwwwwwwwwwwwww",},

  [28]={zoom=1, -- BEACH
  "wwwwwwwwwwwwwwww",
  "w.rv<...c...hhhw",
  "w.r.^..>..c.<d.w",
  "w.r.^..^.c.hhwww",
  "w.r.^..^...c...w",
  "w.r.^..<.cc.<..w",
  "w.r.^..^<..>^..w",
  "wpr.wwwww..wwwww",
  "w.r.vk.........w",
  "w.r.v^w........w",
  "w.r.vhwllllllllw",
  "w.r.vhwllllllllw",
  "w.r.v.wllllllllw",
  "w.r.>^wllllllllw",
  "wwwwwwwwwwwwwwww"},
  [29]={zoom=2,

"wwwwwwww........",
"wk..c..w........",
"wwwwrwrw........",
"w...hccw........",
"w.r.w..w........",
"ww.pw.dw........",
"wwwwwwww........",
"................",
"................",
"................",
"................",
"................",
"................",
"................",
"................",}

 
  --   [27]={zoom=1,
  --   "wwwwwwwwwwwwwwww",
  --   "wwwhhw.p..whhwww",
  --   "wwwhkw....wdhwww",
  --   "ww.rh.w..w.hr.ww",
  --   "ww.hr>....<rh.ww",
  --   "ww.rh.wrrw.hr.ww",
  --   "www..wccccw..www",
  --   "www..wccccw..www",
  --   "ww...wccccw...ww",
  --   "ww...wccccw...ww",
  --   "ww...wccccw...ww",
  --   "www..wccccw..www",
  --   "ww...<....>...ww",
  --   "ww...<....>...ww",
  --   "wwwwwwwwwwwwwwww",
  -- }
}
    
end

function load_level(lvl)
  if lvl>#levels then lvl=1 end
  level=lvl map=levels[level]
  rocks,holes,cracks={}, {}, {}
  key,door=nil,nil
  rock_removal_positions={}
  next_rock_id=0
  forcedconveyor=false

  if (level==0 or level==1) and l_music ~= 10 then
    l_music=10
    music(10)
  end

  if level>1 and level<11 and l_music~=22 then
    l_music=22
    music(22)
  end

  if level>11 and level<21 and l_music ~= 33 then
    l_music=33
    music(33)
  end

  local actions={
    r=function(x,y) make_rock(x,y) end,
    h=function(x,y) add(holes,{x=x,y=y,filled=false}) end,
    c=function(x,y) add(cracks,{x=x,y=y,broken=false}) end,
    k=function(x,y) key={x=x,y=y,collected=false} end,
    d=function(x,y) door={x=x,y=y} end,
    p=function(x,y)
      px,py=x,y target_px,target_py=x,y last_tile_x=x last_tile_y=y
    end
  }

  for y=0,15 do
    local row=map[y+1]
    if row then
      for x=0,15 do
        local ch=sub(row,x+1,x+1)
        if actions[ch] then actions[ch](x*8,y*8) end
      end
    end
  end
  moving=false has_key=false last_direction=nil state_saved=false
  history={} last_snapshot_table=nil rewinding=false
  rewind_move_id=nil last_action_filled=false current_move_id=0
  push_snapshot()
end

---------------------------
-- 5) collision
---------------------------
function collide(x,y,ignore_rocks,cur_rock)
  if x<0 or x>120 or y<0 or y>120 then return true end
  local gx,gy=flr(x/8),flr(y/8)
  local tile=sub(map[gy+1],gx+1,gx+1)
  if tile=="w" or tile=="l" then return true end
  -- if tile =="d" and not has_key then return true end
  if not ignore_rocks and find_entity_at(holes,x,y,function(e) return not e.filled end) then
    return true
  end
  for r in all(rocks) do
    if r~=cur_rock and flr(r.x)==flr(x) and flr(r.y)==flr(y) then return true end
  end
  return false
end

---------------------------
-- 6) master update
---------------------------
function _update()
  -- fuzz_time+=.01
  if     screen_mode=="title"       then update_title()
  elseif screen_mode=="levelselect" then update_level_select()
  else                               update_game() end
end

-- title screen
function update_title()
  if btnp(2) then menu_index=menu_index==1 and 2 or 1 end
  if btnp(3) then menu_index=menu_index==2 and 1 or 2 end
  if btnp(4) or btnp(5) then
    if menu_index==1 then load_level(0) screen_mode="game"
    else screen_mode="levelselect" end
  end
end

-- level select
-- function update_level_select()
--   if btnp(2) then level_select_idx=level_select_idx>1 and level_select_idx-1 or max_levels end
--   if btnp(3) then level_select_idx=level_select_idx<max_levels and level_select_idx+1 or 1 end
--   if btnp(4) or btnp(5) then load_level(level_select_idx) screen_mode="game" end
--   if btnp(1) then screen_mode="title" end
-- end

function update_game()
  if btnp(5) and not moving and not rewinding and #history>0 then
    rewinding=true
    rewind_move_id=deserialize_state(history[#history]).move_id
  end

  if btnp(4) then
    if level + 1 > #levels then
      load_level(0)
    else
      load_level(level + 1)
    end
  end

  -- rewinding animation
  if rewinding then
    if not moving and not any_rock_moving() and #history>0 then
      local snap=deserialize_state(history[#history])
      if snap.move_id == rewind_move_id then
        deli(history, #history)
        revert_to_snapshot(snap)
        target_px, target_py = snap.px, snap.py
        moving = true
        last_snapshot_table = nil  -- Clear the last snapshot so that the next move pushes a new snapshot.
      else
        rewinding = false
      end      
    elseif not moving and not any_rock_moving() then
      rewinding=false
    end
    do_movement_animations()
    return
  end

  -- normal movement / conveyor logic
  do_movement_animations()
  if moving or any_rock_moving() then return end

  if not rewinding then
    for r in all(rocks) do
      if not r.moving then
        local gx,gy=flr(r.x/8),flr(r.y/8)
        if is_conveyor(sub(map[gy+1],gx+1,gx+1)) then
          check_rock_conveyor(r)
        end
      end
    end
  end

  if forcedconveyor then return end
  local dir_btn={left=0,right=1,up=2,down=3}
  local direction=nil
  for d,b in pairs(dir_btn) do if btn(b) then direction=d end end
  if last_direction and btn(dir_btn[last_direction]) then direction=last_direction end
  if direction then
    if not state_saved then 
      current_move_id += 1 
      push_snapshot() 
      state_saved = true 
    end
  
    local dx, dy = 0, 0
    if direction == "left" then 
      dx = -pspeed 
      last_direction = "left"
    elseif direction == "right" then 
      dx = pspeed 
      last_direction = "right"
    elseif direction == "up" then 
      dy = -pspeed 
      last_direction = "up"
    elseif direction == "down" then 
      dy = pspeed 
      last_direction = "down"
    end
    local nx, ny = px + dx, py + dy
    if collide(nx, ny, false, nil) then
      local r = get_rock_at(nx, ny)
      if r then
        local rx, ry = r.x + dx, r.y + dy
        if not collide(rx, ry, true, r) then
          r.target_x, r.target_y = rx, ry 
          r.moving = true
          target_px, target_py = nx, ny 
          moving = true
          -- No second push_snapshot!
        end
      end
    else
      target_px, target_py = nx, ny 
      moving = true
      -- No second push_snapshot!
    end
    state_saved = false
  end
  
end

---------------------------
-- 7) animation / conveyors / snapshot revert
---------------------------
function do_movement_animations()
  -- player
  if moving then
    px=ease(px,target_px) py=ease(py,target_py)
    if abs(px-target_px)<.5 and abs(py-target_py)<.5 then
      px,py=target_px,target_py moving=false last_direction=nil
      if not rewinding then
        local cx,cy=flr(px/8)*8,flr(py/8)*8
        if cx~=last_tile_x or cy~=last_tile_y then
          local pc=get_crack_at(last_tile_x,last_tile_y)
          if pc then
            pc.broken=true
            add(holes,{x=pc.x,y=pc.y,filled=false})
            del(cracks,pc)
          end
          last_tile_x,last_tile_y=cx,cy
        end
        if key and not key.collected and flr(px)==flr(key.x) and flr(py)==flr(key.y) then
          has_key=true key.collected=true sfx(60,3)
        end
        if door and flr(px)==flr(door.x) and flr(py)==flr(door.y) and has_key then
          history={} rewinding=false last_action_filled=false load_level(level+1) return
        end
        check_conveyor_chain_player()
      end
    end
  end

  -- rocks
  for r in all(rocks) do
    if r.moving then
      r.x=ease(r.x,r.target_x) r.y=ease(r.y,r.target_y)
      if abs(r.x-r.target_x)<.5 and abs(r.y-r.target_y)<.5 then
        r.x,r.y=r.target_x,r.target_y r.moving=false
        local cr=get_crack_at(r.x,r.y)
        if not rewinding then
          if l_music == 22 then
            sfx(59,3)
          else
            sfx(59,3)
          end
        end
        if cr and not cr.broken then
          cr.broken=true add(holes,{x=cr.x,y=cr.y,filled=true})
          rock_removal_positions[r.id]={x=r.x,y=r.y} del(rocks,r)
          last_action_filled=true
        else
          local h=get_hole_at(r.x,r.y)
          if h and not h.filled then
            h.filled=true rock_removal_positions[r.id]={x=r.x,y=r.y}
            del(rocks,r) last_action_filled=true
          elseif not rewinding then
            check_rock_conveyor(r)
          end
        end
      end
    end
  end
end

function check_conveyor_chain_player()
  forcedconveyor=false
  while true do
    local gx,gy=flr(px/8),flr(py/8)
    local tile=sub(map[gy+1],gx+1,gx+1)
    if is_conveyor(tile) then
      forcedconveyor=true
      local dx,dy=0,0
      if tile=="v" then dy=8 elseif tile=="^" then dy=-8
      elseif tile==">" then dx=8 else dx=-8 end
      local nx,ny=px+dx,py+dy
      local blocking_rock=get_rock_at(nx,ny)
      if blocking_rock then
        local nrx,nry=blocking_rock.x+dx,blocking_rock.y+dy
        if not collide(nrx,nry,true,blocking_rock) then
          push_snapshot()
          blocking_rock.target_x,blocking_rock.target_y=nrx,nry blocking_rock.moving=true
        else forcedconveyor=false return end
      elseif collide(nx,ny,false,nil) then forcedconveyor=false return end
      push_snapshot() target_px,target_py=nx,ny moving=true return
    else forcedconveyor=false return end
  end
end

function check_rock_conveyor(r)
  local gx,gy=flr(r.x/8),flr(r.y/8)
  local tile=sub(map[gy+1],gx+1,gx+1)
  if not is_conveyor(tile) then return end
  local dx,dy=0,0
  if tile=="v" then dy=8 elseif tile=="^" then dy=-8
  elseif tile==">" then dx=8 else dx=-8 end
  local nx,ny=r.x+dx,r.y+dy
  local rtx,rty=flr(nx/8),flr(ny/8)
  local ptx,pty=moving and flr(target_px/8) or flr(px/8),
                moving and flr(target_py/8) or flr(py/8)
  if rtx==ptx and rty==pty then
    local pnx,pny=(ptx+dx/8)*8,(pty+dy/8)*8
    if not collide(pnx,pny,false,nil) then
      push_snapshot()
      target_px,target_py=pnx,pny
      moving=true
    else return end
  end
  local br=get_rock_at(nx,ny)
  if br and br~=r then
    local nbx,nby=br.x+dx,br.y+dy
    local brtx,brty=flr(nbx/8),flr(nby/8)
    if brtx==ptx and brty==pty then
      local pnx,pny=(ptx+dx/8)*8,(pty+dy/8)*8
      if not collide(pnx,pny,false,nil) then
        push_snapshot()
        target_px,target_py=pnx,pny
        moving=true
      else return end
    end
    if not collide(nbx,nby,true,br) then
      push_snapshot()
      br.target_x,br.target_y=nbx,nby
      br.moving=true
      push_snapshot()
      r.target_x,r.target_y=nx,ny r.moving=true
    end
  elseif not collide(nx,ny,true,r) then
    push_snapshot() r.target_x,r.target_y=nx,ny r.moving=true
  end
end

function revert_to_snapshot(s)
  holes={} for h in all(s.holes) do add(holes,{x=h.x,y=h.y,filled=h.filled}) end
  cracks={} for c in all(s.cracks) do add(cracks,{x=c.x,y=c.y,broken=c.broken}) end
  has_key=s.has_key last_tile_x=s.last_tile_x last_tile_y=s.last_tile_y
  if key then key.collected=s.key_collected end
  local keep={} for r in all(s.rocks) do keep[r.id]=true end
  for r in all(rocks) do if not keep[r.id] then del(rocks,r) end end
  for sr in all(s.rocks) do
    local cr=find_rock_by_id(sr.id)
    if not cr then
      local nr=make_rock(sr.x,sr.y) nr.id=sr.id
      nr.target_x,nr.target_y=sr.x,sr.y nr.moving=true
    else
      cr.target_x,cr.target_y=sr.x,sr.y cr.moving=true
    end
  end
end

---------------------------
-- 8) drawing
---------------------------
function _draw()
  cls()
  if screen_mode=="title" then draw_title()
  elseif screen_mode=="levelselect" then draw_level_select()
  else
    draw_game()
  end
end

function draw_title()
  local o1,o2="START GAME","LEVEL SELECT"

  --     for y = 0, 15 do
  --       for x = 0, 15 do
      
  --         if (y == 3  and x > 1  and x < 14) or     -- top edge
  --            (y == 12 and x > 1  and x < 14) or     -- bottom edge
  --            (x == 1  and y > 3  and y < 12) or     -- left edge
  --            (x == 14 and y > 3  and y < 12) then   -- right edge
  --           spr(64, x*8, y*8)
      
  --         elseif x < 2 or x > 13 or y < 3 or y > 12 then
  --           spr(73, x*8, y*8)
  --         end
      
  --   end
  -- end
  -- spr(1, 42, 54)
  -- spr(1, 48, 54)
  -- sspr(8,0,8,8,40,40,64,64)
  -- sspr(0,64,8,8,40,20,64,64)
  -- sspr(32, 32, 8, 8, 40, 60, 64, 64)

  -- spr(1, 48, 56)
  -- spr(65, 56, 56)
  -- spr(68, 64, 56)
  -- spr(128, 72, 56)


  spr(65, 40, 32)
  spr(65, 80, 32)
  spr(99, 48, 32)
  spr(128, 72, 32)
  spr(194, 56, 32)
  spr(193, 64, 32)
  
  print("\^wO", 37, 50, 7)
  print("\^wC", 45, 50, 7)
  print("\^wT", 53, 50, 7)
  print("\^wO", 61, 50, 7)
  print("\^wR", 69, 50, 7)
  print("\^wO", 77, 50, 7)
  print("\^wQ", 85, 50, 7)

  spr(196, 24, 40)
  spr(197, 32, 40)
  spr(198, 40, 40)
  spr(199, 48, 40)
  spr(200, 56, 40)
  spr(201, 64, 40)
  spr(202, 72, 40)
  spr(203, 80, 40)
  spr(204, 88, 40)
  spr(205, 96, 40)

  -- spr(212, 24, 48)
  -- spr(213, 32, 48)
  spr(214, 40, 48)
  spr(215, 48, 48)
  spr(216, 56, 48)
  spr(217, 64, 48)
  spr(218, 72, 48)
  spr(219, 80, 48)
  -- spr(220, 88, 48)
  -- spr(221, 96, 48)

  spr(212, 24, 48)
  spr(212, 96, 48)

  spr(228, 24, 56)
  spr(229, 32, 56)
  spr(230, 40, 56)
  spr(231, 48, 56)
  spr(232, 56, 56)
  spr(233, 64, 56)
  spr(234, 72, 56)
  spr(235, 80, 56)
  spr(236, 88, 56)
  spr(237, 96, 56)

  spr(244, 24, 64)
  spr(245, 32, 64)
  spr(246, 40, 64)
  spr(247, 48, 64)
  spr(248, 56, 64)
  spr(249, 64, 64)
  spr(250, 72, 64)
  spr(251, 80, 64)
  spr(252, 88, 64)
  spr(253, 96, 64)

  print((menu_index==1 and ">" or " ")..o1,38,92,7)
  print((menu_index==2 and ">" or " ")..o2,38,102,7)
  -- print("\^w\^tOCTOROQ",37,40,7)
  print("\^-w\^-tyamsoft", 101, 123, 3)
end

-- Replace the existing `draw_level_select` function with the new grid-based layout:

-- Replace the existing `draw_level_select` function with the new grid-based layout:

  function draw_level_select()
    cls()
    -- print("SELECT LEVEL", 40, 8, 7)
    print("❎ to start  ➡️ back", 16, 120, 6)
  
    local col_x = {8, 48, 88} -- starting x positions for columns
    local card_w, card_h = 36, 10
    local v_spacing = 12
  
    for i = 1, max_levels do
      local col = ceil(i / 10)
      local row = (i - 1) % 10
  
      local x = col_x[col]
      local y = 0 + row * v_spacing
  
      local colr = (i == level_select_idx) and 10 or 7
      rectfill(x, y, x + card_w - 1, y + card_h - 1, (i == level_select_idx) and 1 or 5)
      rect(x, y, x + card_w - 1, y + card_h - 1, colr)
      print(i, x + 2, y + 2, colr)
    end
  end
  
  -- Replace `update_level_select` with new navigation logic for 3-column layout
  function update_level_select()
    local col = ceil(level_select_idx / 10)
    local row = (level_select_idx - 1) % 10
  
    if btnp(2) then -- up
      row = (row - 1 + 10) % 10
    elseif btnp(3) then -- down
      row = (row + 1) % 10
    elseif btnp(0) then -- left
      col = (col - 2 + 3) % 3 + 1
    elseif btnp(1) then -- right
      col = (col % 3) + 1
    elseif btnp(4) or btnp(5) then
      load_level(level_select_idx)
      screen_mode = "game"
    end
  
    level_select_idx = mid(1, (col - 1) * 10 + row + 1, max_levels)
  
    if btnp(6) then screen_mode = "title" end -- back to title
  end
  

function draw_game()
  local z=map.zoom or 1
  for y=0,15 do
    local row=map[y+1]
    for x=0,15 do
      local ch=sub(row,x+1,x+1)
      local sx,sy=x*8,y*8
      if ch=="." then
        draw_sprite(83,sx,sy,z)
      elseif ch=="," then
        draw_sprite(84,sx,sy,z)
      elseif char==";" then
        draw_sprite(82,sx,sy,z)
      elseif char==":" then
        draw_sprite(81,sx,sy,z)
      elseif ch=="w" then
        draw_sprite(64,sx,sy,z)
      elseif ch=="l" then
        draw_sprite(94,sx,sy,z)
      elseif ch=="1" then
        draw_sprite(77,sx,sy,z)
      elseif ch=="2" then
        draw_sprite(126,sx,sy,z)
      elseif ch=="3" then
        draw_sprite(78,sx,sy,z)
      elseif ch=="4" then
        draw_sprite(110,sx,sy,z)
      elseif ch=="g" then
        draw_sprite(36,sx,sy,z)
      elseif ch=="b" then
        draw_sprite(51,sx,sy,z)
      elseif ch=="c" then
        if get_crack_at(sx,sy) then draw_sprite(66,sx,sy,z) end
      else
        local sp=conveyor_sprite(ch)
        if sp then draw_sprite(sp,sx,sy,z) end
      end
    end
  end

  for h in all(holes) do
    draw_sprite(h.filled and 69 or 68,h.x,h.y,z)
  end
  if key and not key.collected then draw_sprite(128,key.x,key.y,z) end
  if door then draw_sprite(has_key and 99 or 99,door.x,door.y,z) end

  for r in all(rocks) do
    -- local fx=r.x+cos(fuzz_time+r.x*.1)*.15
    -- local fy=r.y+cos(fuzz_time+r.y*.1)*.15
    -- if r.moving then fx,fy=r.x,r.y end
    draw_sprite(65,r.x,r.y,z)
  end
  draw_sprite(frame,px,py,z)

  print("level "..level,96,122,7)
  print("octoroq ",0,122,122)
  if level == 1 then
    print("Stuck? Press ❎ to rewind", 16, 30, 7)
  end
  if level == 0 then
    spr(69, 72, 8)
    spr(1, 40, 24)
    spr(193, 48, 24)
    spr(128, 56, 24)
    spr(193, 64, 24)
    spr(99, 72, 24)
  end
end
