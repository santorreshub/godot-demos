# Godot Demos — Santiago Torres

**Play in your browser:** https://santorreshub.github.io/godot-demos/

Three small Godot 4.3 games written entirely in GDScript, with no imported assets: every mesh, map, sprite and effect is built in code.

| Game | Type | What it shows |
| --- | --- | --- |
| [Dispatch: Beat the AI Broker](https://santorreshub.github.io/godot-demos/dispatch/) | 2D strategy | Utility-AI opponent, brokerage economics, procedural UI |
| [Flatbed Hauler](https://santorreshub.github.io/godot-demos/flatbed_hauler/) | 3D driving | VehicleBody3D, rigid-body cargo, risk/time trade-offs |
| [Ōllamaliztli](https://santorreshub.github.io/godot-demos/ollama/) | 2D arcade | Physics gameplay, hitboxes, particles, procedural art |

## Repo layout
- `games/` — Godot project for each game (open `project.godot` in Godot 4.3+)
- `index.html`, `dispatch/`, `flatbed_hauler/`, `ollama/` — web exports served by GitHub Pages

## Rebuild the web versions
In each game folder: Godot → Project → Export → Web → Export Project (single-threaded build, so it runs on GitHub Pages without special headers).

Built by [Santiago Torres](https://www.linkedin.com/in/santorreswork).
