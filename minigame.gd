## Sumo Ring: knock everyone off a floating ring. This folder is its own git repo.
## MAPS is what the game knows about this minigame (see Arena.maps).

const MAPS := {
	sumo = {name = "Sumo Ring", map = "Sumo Ring", rules = "Knock everyone off the ring. Last bowler standing wins.",
		seconds = 60.0, arena = preload("sumo_ring.gd")},
}
