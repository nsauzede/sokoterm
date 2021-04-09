// Copyright (c) 2020 Nicolas Sauzede. All rights reserved.
// Use of this source code is governed by the MIT license distributed with this software.
import term
import term.ui
import time
import os

const (
	black       = ui.Color{0, 0, 0}
	white       = ui.Color{255, 255, 255}
	//
	version     = 1
	empty       = 0x0
	store       = 0x1
	crate       = 0x2
	wall        = 0x4
	//
	c_empty     = ` `
	c_store     = `.`
	c_stored    = `*`
	c_crate     = `$`
	c_player    = `@`
	c_splayer   = `+`
	c_wall      = `#`
	e_empty     = '  '
	e_store     = '🎀'
	e_stored    = '🎁'
	e_crate     = '📦'
	e_player    = '👷'
	e_splayer   = '👷'
	e_wall      = '🧱'
	//
	root_dir    = os.resource_abs_path('.')
	res_dir     = os.resource_abs_path('./res')
	levels_file = res_dir + '/levels/levels.txt'
	scores_file = root_dir + '/scores.txt'
)

enum Status {
	menu
	play
	pause
	win
}

struct Level {
	crates int // number of crates
mut:
	w      int // map dims
	h      int // map dims
	map    [][]byte // map
	stored int // number of stored crates
	px     int // player pos
	py     int // player pos
}

struct Score {
mut:
	// version byte = version
	level  u16
	moves  u16
	pushes u16
	time_s u32
}

struct Snapshot {
mut:
	state       State
	undo_states []State
}

struct State {
mut:
	map    [][]byte
	moves  int
	pushes int
	time_s u32
	stored int
	px     int
	py     int
	undos  int
}

struct App {
mut:
	tui        &ui.Context = 0
	width      int
	height     int
	dt         f32
	ticks      i64
	// Game flags and status
	status     Status = .menu
	debug      bool
	// Game levels
	levels     []Level
	level      int // current level
	// Game states
	snapshots  []Snapshot // saved snapshots (currently only one max)
	snap       Snapshot // current snapshot : state + undo_states
	last_ticks i64
	scores     []Score
}

fn (mut a App) init() {
	w, h := a.tui.window_width, a.tui.window_height
	a.width = w
	a.height = h
	term.erase_del_clear()
	term.set_cursor_position({
		x: 0
		y: 0
	})
	a.levels = load_levels()
	a.scores = load_scores()
	mut dones := [false].repeat(a.levels.len)
	for score in a.scores {
		if score.level >= 0 && score.level < a.levels.len {
			dones[score.level] = true
		}
	}
	mut level := 0
	for done in dones {
		if !done {
			break
		}
		level++
	}
	a.set_level(level)
}

fn (mut a App) start_game() {
	if a.status != .play {
		a.status = .play
	}
}

fn (a App) save_state(mut state State, full bool) {
	unsafe {
		*state = a.snap.state
	}
	mut map := [][]byte{}
	if full {
		map = a.snap.state.map.clone()
	}
	state.map = map
}

fn (mut a App) restore_state(state State) {
	map := a.snap.state.map
	a.snap.state = state
	if state.map.len == 0 {
		a.snap.state.map = map
	}
}

fn (mut a App) save_snapshot() {
	a.snapshots = []Snapshot{} // limit snapshots depth to 1
	a.snapshots << Snapshot{
		undo_states: a.snap.undo_states.clone()
	}
	a.save_state(mut a.snapshots[0].state, true)
	// a.debug_dump()
}

fn (mut a App) load_snapshot()? {
	if a.snapshots.len > 0 {
		snap := a.snapshots.pop()
		a.snap.undo_states = snap.undo_states
		a.restore_state(snap.state)
		save_scores(a.scores)?
		a.save_snapshot() // limit snapshots depth to 1
	}
}

fn (mut a App) frame() {
	ticks := time.ticks()
	a.dt = f32(ticks - a.ticks) / 1000.0
	a.width, a.height = a.tui.window_width, a.tui.window_height
	a.tui.clear()
	a.render()
	a.tui.flush()
	a.ticks = ticks
}

fn (mut a App) save_score() {
	mut push_score := true
	for score in a.scores {
		if score.level == a.level {
			push_score = false
		}
	}
	if push_score {
		s := Score{
			level: u16(a.level)
			moves: u16(a.snap.state.moves)
			pushes: u16(a.snap.state.pushes)
			time_s: a.snap.state.time_s
		}
		a.scores << s
	}
}

fn save_scores(scores []Score)? {
	if scores.len > 0 {
		os.rm(scores_file)? // TODO : understand why create doesn't reset contents
		mut f := os.create(scores_file) or {
			panic("can't create scores file")
		}
		f.writeln('$version')?
		f.writeln('$scores.len')?
		for s in scores {
			f.writeln('$s.level $s.pushes $s.moves $s.time_s')?
		}
	}
}

fn load_scores() []Score {
	mut ret := []Score{}
	mut nscores := 0
	contents := os.read_file(scores_file) or {
		return ret
	}
	mut n := 0
	for line in contents.split_into_lines() {
		if n == 0 {
			ver := line.int()
			if ver != version {
				panic('Invalid scores version. Please delete the scores file $scores_file' + '.')
			}
		} else if n == 1 {
			nscores = line.int()
		} else {
			v := line.split(' ').map(it.int())
			ret << Score{u16(v[0]), u16(v[1]), u16(v[2]), u32(v[3])}
		}
		n++
	}
	if nscores != ret.len {
		panic('Invalid number of scores (read $nscores parsed $ret.len). Please delete the scores file $scores_file' +
			'.')
	}
	return ret
}

fn (mut a App) pop_undo()? {
	if a.snap.undo_states.len > 0 {
		state := a.snap.undo_states.pop()
		a.restore_state(state)
		save_scores(a.scores)?
		a.snap.state.undos++
		// a.debug_dump()
	}
}

fn (mut a App) push_undo(full bool) {
	mut state := State{}
	a.save_state(mut state, full)
	a.snap.undo_states << state
}

fn load_levels() []Level {
	mut levels := []Level{}
	mut vlevels := []string{}
	mut slevel := ''
	slevels := os.read_file(levels_file.trim_space()) or {
		panic('Failed to open levels file')
	}
	for line in slevels.split_into_lines() {
		if line.len == 0 {
			if slevel.len > 0 {
				vlevels << slevel
				slevel = ''
			}
			continue
		}
		if line.starts_with(';') {
			continue
		}
		slevel = slevel + '\n' + line
	}
	if slevel.len > 0 {
		vlevels << slevel
	}
	for s in vlevels {
		mut map := [][]byte{}
		mut crates := 0
		mut stores := 0
		mut stored := 0
		mut w := 0
		mut h := 0
		mut px := 0
		mut py := 0
		mut player_found := false
		for line in s.split_into_lines() {
			if line.len > w {
				w = line.len
			}
		}
		for line in s.split_into_lines() {
			if line.len == 0 {
				continue
			}
			mut v := [byte(empty)].repeat(w)
			for i, e in line {
				match e {
					c_empty {
						v[i] = empty
					}
					c_store {
						v[i] = store
						stores++
					}
					c_crate {
						v[i] = crate
						crates++
					}
					c_stored {
						v[i] = crate | store
						stores++
						crates++
						stored++
					}
					c_player {
						if player_found {
							panic('Player found multiple times in level')
						}
						px = i
						py = h
						player_found = true
						v[i] = empty
					}
					c_splayer {
						if player_found {
							panic('Player found multiple times in level')
						}
						px = i
						py = h
						player_found = true
						v[i] = store
						stores++
					}
					c_wall {
						v[i] = wall
					}
					else {
						panic('Invalid element [$e.str()] in level')
					}
				}
			}
			map << v
			h++
		}
		if crates != stores {
			panic('Mismatch between crates=$crates and stores=$stores in level')
		}
		if !player_found {
			panic('Player not found in level')
		}
		levels << Level{
			map: map
			crates: crates
			stored: stored
			w: w
			h: h
			px: px
			py: py
		}
	}
	return levels
}

fn (mut a App) set_level(level int) bool {
	if level < a.levels.len {
		// a.status = .play
		a.level = level
		a.snap = Snapshot{
			state: State{
				map: a.levels[a.level].map.clone()
			}
		}
		a.snap.undo_states = []State{}
		a.snap.state.undos = 0
		a.snapshots = []Snapshot{}
		a.snap.state.stored = a.levels[a.level].stored
		a.levels[a.level].w = a.levels[a.level].w
		a.levels[a.level].h = a.levels[a.level].h
		a.snap.state.moves = 0
		a.snap.state.pushes = 0
		a.snap.state.time_s = 0
		a.last_ticks = time.ticks()
		a.snap.state.px = a.levels[a.level].px
		a.snap.state.py = a.levels[a.level].py
		// a.debug_dump()
		return true
	} else {
		return false
	}
}

fn (mut a App) quit()? {
	if a.status != .menu {
		if a.status == .play || a.status == .win {
			a.status = .menu
		}
		return
	}
	term.set_cursor_position({
		x: 0
		y: 0
	})
	save_scores(a.scores)?
	exit(0)
}

fn (mut a App) can_move(x int, y int) bool {
	if x < a.levels[a.level].w && y < a.levels[a.level].h {
		e := a.snap.state.map[y][x]
		if e == empty || e == store {
			return true
		}
	}
	return false
}

// Try to move to x+dx:y+dy and possibly also push from x+dx:y+dy to x+2dx:y+2dy
fn (mut a App) try_move(dx int, dy int)? bool {
	mut do_it := false
	x := a.snap.state.px + dx
	y := a.snap.state.py + dy
	if a.snap.state.map[y][x] & crate == crate {
		to_x := x + dx
		to_y := y + dy
		if a.can_move(to_x, to_y) {
			do_it = true
			a.push_undo(true)
			a.snap.state.pushes++
			a.snap.state.map[y][x] &= ~crate
			if a.snap.state.map[y][x] & store == store {
				a.snap.state.stored--
			}
			a.snap.state.map[to_y][to_x] |= crate
			if a.snap.state.map[to_y][to_x] & store == store {
				a.snap.state.stored++
				if a.snap.state.stored == a.levels[a.level].crates {
					a.status = .win
					a.save_score()
					save_scores(a.scores)?
				}
			}
		}
	} else {
		do_it = a.can_move(x, y)
		if do_it {
			a.push_undo(false)
		}
	}
	if do_it {
		a.snap.state.moves++
		a.snap.state.px = x
		a.snap.state.py = y
		// a.debug_dump()
	}
	return do_it
}

fn (mut a App) event(e &ui.Event)? {
	match e.typ {
		.key_down {
			if e.code == .escape {
				a.quit()?
			}
		}
		else {}
	}
	match a.status {
		.menu { a.handle_event_menu(e) }
		.win { a.handle_event_win(e)? }
		.play { a.handle_event_play(e)? }
		.pause { a.handle_event_pause(e) }
	}
}

fn (mut a App) handle_event_play(e &ui.Event)? {
	match e.typ {
		.key_down { match e.code {
				.space { a.status = .pause }
				.r { a.set_level(a.level) }
				.u { a.pop_undo()? }
				.s { a.save_snapshot() }
				.l { a.load_snapshot()? }
				.w { a.status = .win }
				.left { a.try_move(-1, 0)? }
				.right { a.try_move(1, 0)? }
				.up { a.try_move(0, -1)? }
				.down { a.try_move(0, 1)? }
				else {}
			} }
		else {}
	}
}

fn (mut a App) handle_event_pause(e &ui.Event) {
	match e.typ {
		.key_down { match e.code {
				.space { a.status = .play }
				else {}
			} }
		else {}
	}
}

fn (mut a App) handle_event_menu(e &ui.Event) {
	match e.typ {
		.key_down { match e.code {
				.enter { a.start_game() }
				else {}
			} }
		else {}
	}
}

fn (mut a App) handle_event_win(e &ui.Event)? {
	match e.typ {
		.key_down { match e.code {
				.enter {
					if a.set_level(a.level + 1) {
						a.status = .play
					} else {
						eprintln('Game over.')
						a.quit()?
					}
				}
				else {}
			} }
		else {}
	}
}

fn (mut a App) free() {
}

fn (mut a App) render() {
	match a.status {
		.menu { a.draw_menu() }
		else { a.draw_game() }
	}
}

fn (mut a App) draw_menu() {
	cx := int(f32(a.width) * 0.5)
	y025 := int(f32(a.height) * 0.25)
	y075 := int(f32(a.height) * 0.75)
	cy := int(f32(a.height) * 0.5)
	//
	a.tui.set_color(white)
	a.tui.bold()
	a.tui.draw_text(cx - 5, y025, 'Sokoterm')
	a.tui.reset()
	a.tui.draw_text(cx - 16, y025 + 1, '(A Sokoban-like game written in V)')
	//
	a.tui.set_color(white)
	a.tui.bold()
	a.tui.draw_text(cx - 7, cy + 1, 'Enter to start ${a.level + 1}')
	a.tui.draw_text(cx - 5, cy + 2, 'ESC to Quit')
	a.tui.reset()
	//
	a.tui.draw_text(cx - 9, y075 + 1, 'SPACE : Pause game')
	a.tui.draw_text(cx - 9, y075 + 2, 'R : Reset level')
	a.tui.draw_text(cx - 9, y075 + 3, 'U : Undo last move')
	a.tui.draw_text(cx - 9, y075 + 4, 'S : Save Snapshot')
	a.tui.draw_text(cx - 9, y075 + 5, 'L : Load Snapshot')
	a.tui.reset()
}

fn (mut a App) draw_game() {
	curr_ticks := time.ticks()
	if curr_ticks > a.last_ticks + 1000 {
		if a.status == .play {
			a.snap.state.time_s += u32(f32(curr_ticks - a.last_ticks) / 1000.)
		}
		a.last_ticks = curr_ticks
	}
	mut gfx := a.tui
	for j, line in a.snap.state.map {
		for i, e in line {
			x := (a.width - a.levels[a.level].w * 2) / 2 + i * 2
			y := (a.height - a.levels[a.level].h) / 2 + j
			ee := match e {
				store {
					if a.snap.state.px == i && a.snap.state.py == j { e_splayer } else { e_store }
				}
				crate {
					e_crate
				}
				wall {
					e_wall
				}
				crate | store {
					e_stored
				}
				empty {
					s:=if a.snap.state.px == i && a.snap.state.py == j { e_player } else { e_empty }
					s
				}
				else {
					e_empty
				}
			}
			gfx.draw_text(x, y, ee)
		}
	}
	status := match a.status {
		.win { 'You win! Press Return..' }
		.pause { '*PAUSE* Press Space..' }
		else { '' }
	}
	ts := a.snap.state.time_s % 60
	tm := (a.snap.state.time_s / 60) % 60
	th := a.snap.state.time_s / 3600
	str := '${a.level + 1:02d}| moves: ${a.snap.state.moves:04d} pushes: ${a.snap.state.pushes:04d} time:$th:${tm:02}:${ts:02} $status'
	mut i := (a.width - str.len) / 2
	mut j := (a.height + a.levels[a.level].h) / 2 + 1
	gfx.draw_text(i, j, str)
}

// TODO Remove these wrapper functions when we can assign methods as callbacks
fn init(x voidptr) {
	mut app := &App(x)
	app.init()
}

fn frame(x voidptr) {
	mut app := &App(x)
	app.frame()
}

fn cleanup(x voidptr) {
	mut app := &App(x)
	app.free()
}

fn fail(error string) {
	eprintln(error)
}

fn event(e &ui.Event, x voidptr)? {
	mut app := &App(x)
	app.event(e)?
}

// main
mut app := &App{}
app.tui = ui.init({
	user_data: app
	init_fn: init
	frame_fn: frame
	cleanup_fn: cleanup
	event_fn: event
	fail_fn: fail
	capture_events: true
	hide_cursor: true
	frame_rate: 60
})
app.tui.run()?
