# Sumo Ring

A [Party Park](https://github.com/Slurms602/Party-Park) minigame: a round clay ring floating over the sea. Knock
everyone off it. Everyone still on the ring scores each time someone goes over, and the last one standing gets +3.

This repo is one folder of the game: it's mounted at `game/minigames/sumo` in Party-Park and can't run on its own.
To work on it, clone Party-Park with `--recursive` and work in that folder. Party-Park's `CLAUDE.md` explains how
minigames plug in.

- `minigame.gd`: how the game lists this minigame (name, rules, length)
- `sumo_ring.gd`: the ring, the scoring, and what bots do with someone they're carrying
