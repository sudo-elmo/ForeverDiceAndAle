-- Offline test for the game rules and game flow (no WoW client needed).
-- Run from the addon folder:  lua5.1 tests/rules_test.lua .
local dir = arg[1] or "."
local ns = {}
loadfile(dir.."/Rules.lua")("ForeverDiceAndAle", ns)
time = os.time
loadfile(dir.."/Game.lua")("ForeverDiceAndAle", ns)
local R, G = ns.Rules, ns.Game
local fails = 0
local function eq(a,b,msg) if a~=b then fails=fails+1 print("FAIL",msg,a,b) end end
eq(R.ScoreFor("threes",{3,3,1,3,5}),9,"threes")
eq(R.ScoreFor("three",{3,3,1,3,5}),15,"3kind")
eq(R.ScoreFor("three",{3,2,1,3,5}),0,"3kind no")
eq(R.ScoreFor("four",{6,6,6,6,1}),25,"4kind")
eq(R.ScoreFor("four",{6,6,6,6,6}),30,"4kind from kniffel")
eq(R.ScoreFor("full",{2,2,5,5,5}),25,"full")
eq(R.ScoreFor("full",{5,5,5,5,5}),0,"kniffel is no full house")
eq(R.ScoreFor("small",{1,2,3,4,6}),30,"small")
eq(R.ScoreFor("small",{3,4,5,6,6}),30,"small2")
eq(R.ScoreFor("small",{2,3,4,5,6}),30,"small from large")
eq(R.ScoreFor("small",{1,2,3,5,6}),0,"small no")
eq(R.ScoreFor("large",{2,3,4,5,6}),40,"large")
eq(R.ScoreFor("large",{1,2,3,4,6}),0,"large no")
eq(R.ScoreFor("five",{4,4,4,4,4}),50,"five")
eq(R.ScoreFor("five",{4,4,4,4,3}),0,"kniffel no")
eq(R.ScoreFor("chance",{1,2,3,4,6}),16,"chance")
eq(R.ScoreFor("ones",{0,2,3,4,6}),0,"invalid")
local p = R.NewPlayer("x")
eq(R.ApplyScore(p,"five",{4,4,4,4,4}),50,"apply kniffel")
eq(R.ApplyScore(p,"five",{2,2,2,2,2}),nil,"filled")
eq(R.ApplyScore(p,"large",{2,2,2,2,2}),0,"second kniffel no joker")
eq(R.Totals(p).total,50,"total")
local u=R.NewPlayer("u")
for i,c in ipairs(R.UPPER) do R.ApplyScore(u,c,{i,i,i,1,2}) end
local t=R.Totals(u); eq(t.upper,66,"upper"); eq(t.bonus,35,"bonus"); eq(t.total,101,"total upper")
local v=R.NewPlayer("v"); R.ApplyScore(v,"sixes",{6,6,1,1,1}); eq(R.Totals(v).bonus,0,"no bonus")
math.randomseed(1)
for game=1,200 do
  G:Start({mode="solo",players={"me"},localName="me"})
  local guard=0
  while not G.state.finished do
    guard=guard+1; assert(guard<100)
    assert(G:Roll()); if math.random()<0.5 then G:ToggleHold(1) G:Roll() end
    for _,c in ipairs(R.ALL) do if G:CurrentPlayer().scores[c]==nil then assert(G:Score(c)) break end end
  end
  assert(R.IsComplete(G.state.players[1]))
end
G:Start({mode="net",players={"A","B","C"},localName="A",gameId="g"})
assert(G:IsLocalTurn()); G:Roll(); G:Score("chance")
eq(G.state.current,2,"to B")
eq(G:RemoteScore("C",G.state.turn,"chance","11111"),false,"out of turn")
eq(G:RemoteScore("B",G.state.turn,"five","66666"),true,"B kniffel")
eq(G.state.players[2].scores.five,50,"B 50")
G:RemovePlayer("C"); eq(G.state.current,1,"skip C")
for i=1,12 do G:Roll(); for _,c in ipairs(R.ALL) do if G:CurrentPlayer().scores[c]==nil then G:Score(c) break end end
  if not G.state.finished then for _,c in ipairs(R.ALL) do if G:CurrentPlayer().scores[c]==nil then G:RemoteScore("B",G.state.turn,c,"12345") break end end end end
eq(G.state.finished,true,"net finished")
print(fails==0 and "ALL OK" or (fails.." failures"))
if fails > 0 then os.exit(1) end
