package main

import "core:fmt"
import os "core:os"
import "core:strings"
import rl "vendor:raylib"
// Flags
DEBUG: bool = true

// Data Types
Block_ID :: distinct u64
Page_ID :: u64

// Config
File_Dir := "/.local/share/synapse/"
Default_Padding: i32 = 2

CURRENT_PANE_INDEX: int = 0 // index of the pane that has keyboard focus

// Data Writing
write_u8 :: proc(fd: os.Handle, v: u8) {os.write(fd, []u8{v})}
write_u32 :: proc(fd: os.Handle, v: u32) {b := transmute([4]u8)v; os.write(fd, b[:])}
wite_u64 :: proc(fd: os.Handle, v: u64) {b := transmute([8]u8)v; os.write(fd, b[:])}
write_string :: proc(fd: os.Handle, s: string) {
	write_u32(fd, u32(len(s)))
	os.write(fd, transmute([]u8)s)
}

// File Saving
save_page :: proc(page: ^Page) {
	// ~ is not expanded by the OS; resolve via $HOME
	home := os.get_env("HOME")
	dir := strings.concatenate({home, File_Dir})
	defer delete(dir)

	if !os.is_dir_path(dir) {
		if err := os.make_directory(dir); err != os.ERROR_NONE {
			fmt.eprintln("save_page: failed to create directory:", err)
			return
		}
	}

	// Use page id as filename to avoid issues with special chars in titles
	file_path := fmt.tprintf("%s/%v.syn", dir, page.id)
	fd, err := os.open(file_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if err != os.ERROR_NONE {
		fmt.eprintln("save_page: failed to open file:", err)
		return
	}
	defer os.close(fd)

	// Page metadata
	wite_u64(fd, page.id)
	write_string(fd, page.title)

	// Block store metadata
	wite_u64(fd, u64(page.store.next_id))

	// Root order (preserves block sequence)
	write_u32(fd, u32(len(page.store.root_order)))
	for id in page.store.root_order {
		wite_u64(fd, u64(id))
	}

	// All blocks
	write_u32(fd, u32(len(page.store.blocks)))
	for _, block in page.store.blocks {
		wite_u64(fd, u64(block.id))
		write_u8(fd, u8(block.type))
		wite_u64(fd, u64(block.parent))

		write_u32(fd, u32(len(block.children)))
		for child_id in block.children {
			wite_u64(fd, u64(child_id))
		}

		switch d in block.data {
		case BlockText:
			write_string(fd, strings.to_string(d.content))
		case BlockHeading:
			write_string(fd, strings.to_string(d.content))
		case BlockTodo:
			write_string(fd, strings.to_string(d.content))
			write_u8(fd, 1 if d.checked else 0)
		case:
			write_string(fd, "")
		}
	}
}

BlockType :: enum {
	Text,
	Todo,
	Heading,
}

// Blocks
BlockText :: struct {
	content: strings.Builder,
}

BlockTodo :: struct {
	content: strings.Builder,
	checked: bool,
}

BlockHeading :: struct {
	content: strings.Builder,
}

BlockData :: union {
	BlockHeading,
	BlockText,
	BlockTodo,
}

Block :: struct {
	id:       Block_ID,
	type:     BlockType,
	data:     BlockData,
	parent:   Block_ID,
	children: [dynamic]Block_ID,
}

// Page is the data/content layer — the document itself. Save this to disk.
Page :: struct {
	id:    Page_ID,
	title: string,
	store: ^BlockStore,
}

Page_Store :: struct {
	pages:      map[Page_ID]Page,
	root_order: [dynamic]Page_ID,
	next_id:    Page_ID,
}

BlockStore :: struct {
	blocks:     map[Block_ID]Block,
	root_order: [dynamic]Block_ID, // explicit ordering; map has no guaranteed order
	next_id:    Block_ID,
}

// Pane is the view/UI layer — a viewport into a Page. Save this for session restore only.
Pane :: struct {
	page_id:  Page_ID, // which page this pane is showing
	position: int, // scroll position
	line_num: int,
	blocks:   ^BlockStore, // pointer to the Page's BlockStore; pane doesn't own this data
}

// States
Window_State :: struct {
	size_x:     i32,
	size_y:     i32,
	target_fps: i32,
	panes:      [dynamic]Pane,
	font:       rl.Font,
}

Global_State :: struct {
	running: bool,
	debug:   bool,
	store:   Page_Store,
	window:  Window_State,
	cursor:  Cursor_State,
}

Cursor_State :: struct {
	key_repeat_state: Key_Repeat,
	block_id:         Block_ID,
	char_offset:      int,
}

// Fires once on press, waits initial_delay, then repeats every repeat_delay while held.
Key_Repeat :: struct {
	initial_delay: f32,
	repeat_delay:  f32,
	timer:         f32,
	held_key:      rl.KeyboardKey,
}

Key_Binding :: struct {
	name:           string,
	description:    string,
	primary_key:    rl.KeyboardKey,
	secondary_key:  rl.KeyboardKey,
	primary_ctrl:   bool,
	primary_alt:    bool,
	secondary_ctrl: bool,
	secondary_alt:  bool,
}

New_Pane_Keybind := Key_Binding {
	name         = "New Pane",
	description  = "Creates a new pane",
	primary_key  = .N,
	primary_ctrl = true,
}

// Themes
Theme :: struct {
	bg:        rl.Color,
	panel:     rl.Color,
	text:      rl.Color,
	text_dim:  rl.Color,
	selection: rl.Color,
	accent:    rl.Color,
}

Gruvbox :: Theme {
	bg        = {29, 32, 33, 255}, // #1d2021
	panel     = {40, 40, 40, 255}, // #282828
	text      = {235, 219, 178, 255}, // #ebdbb2
	text_dim  = {168, 153, 132, 255}, // #a89984
	selection = {80, 73, 69, 255}, // #504945
	accent    = {184, 187, 38, 255}, // #b8bb26 (Green)
}

create_page :: proc(page_store: ^Page_Store) -> Page_ID {
	_id := page_store.next_id
	page_store.next_id += 1

	store := new(BlockStore)
	store.blocks = make(map[Block_ID]Block)
	store.root_order = make([dynamic]Block_ID)
	store.next_id = 1

	page_store.pages[_id] = Page {
		id    = _id,
		title = "New Page",
		store = store,
	}
	append(&page_store.root_order, _id)

	return _id
}

get_page :: proc(store: ^Page_Store, id: Page_ID) -> ^Page {
	if id in store.pages {
		return &store.pages[id]
	}
	return nil
}

load_page :: proc(state: ^Global_State, page_id: Page_ID) {
	blocks := state.store.pages[page_id].store
	state.window.panes[CURRENT_PANE_INDEX].page_id = page_id
	state.window.panes[CURRENT_PANE_INDEX].blocks = blocks
	if len(blocks.root_order) > 0 {
		state.cursor.block_id = blocks.root_order[0]
		state.cursor.char_offset = 0
	}
}

init_store :: proc() -> Page_Store {
	return Page_Store {
		pages = make(map[Page_ID]Page),
		root_order = make([dynamic]Page_ID),
		next_id = 1,
	}
}

//// Blocks ////
create_block :: proc(
	store: ^BlockStore,
	type: BlockType,
	data: BlockData = nil,
	parent_id: Block_ID = 0,
) -> Block_ID {
	// 1. Generate the ID
	new_id := store.next_id
	store.next_id += 1

	_data := data
	if _data == nil {
		switch type {
		case .Text:
			_data = BlockText {
				content = strings.builder_make(),
			}

		case .Todo:
			_data = BlockTodo {
				content = strings.builder_make(),
				checked = false,
			}

		case .Heading:
			_data = BlockHeading {
				content = strings.builder_make(),
			}
		}
	}
	// 2. Create the Data Struct
	new_block := Block {
		id       = new_id,
		type     = type,
		data     = _data,
		parent   = parent_id,
		children = make([dynamic]Block_ID),
	}

	// 3. Insert into the "Pool" (The Map)
	store.blocks[new_id] = new_block

	// 4. Link it to the Structure
	if parent_id == 0 {
		// CASE A: Top-Level Block (No Parent)
		append(&store.root_order, new_id)
	} else {
		// CASE B: Nested Block (Has Parent)
		if parent_ptr, ok := &store.blocks[parent_id]; ok {
			append(&parent_ptr.children, new_id)
		} else {
			// Edge Case: The parent_id provided doesn't exist.
			// Safety fallback: Add to root so we don't lose the data.
			append(&store.root_order, new_id)
		}
	}

	fmt.printfln("New Block With ID: %i", new_id)
	return new_id
}

move_block :: proc(store: ^BlockStore, block_id: Block_ID, new_block_id: Block_ID) {
	if block_id == new_block_id {return}
	if !(block_id in store.blocks) || !(new_block_id in store.blocks) {return}

	from_index := -1
	to_index := -1
	for id, i in store.root_order {
		if id == block_id {from_index = i}
		if id == new_block_id {to_index = i}
	}
	if from_index == -1 || to_index == -1 {return}

	ordered_remove(&store.root_order, from_index)
	if to_index > from_index {to_index -= 1} 	// adjust for the removal shifting indices down
	inject_at(&store.root_order, to_index, block_id)
}

delete_block :: proc(store: ^BlockStore, block_id: Block_ID) -> bool {
	// Retrieve the block to delete
	block := store.blocks[block_id] or_return

	// Identify target and determine the new parent ID
	target_list: ^[dynamic]Block_ID
	new_parent_id: Block_ID

	if block.parent == 0 {
		target_list = &store.root_order
		new_parent_id = 0
	} else {
		if parent, ok := &store.blocks[block.parent]; ok {
			target_list = &parent.children
			new_parent_id = block.parent
		} else {
			// Fallback: Parent missing, move to root
			target_list = &store.root_order
			new_parent_id = 0
		}
	}

	// Update the parent reference using the correct ID
	for child_id in block.children {
		if child, ok := &store.blocks[child_id]; ok {
			child.parent = new_parent_id
		}
	}

	// Splice: Remove the block and insert its children in place
	index_to_replace := -1
	for id, i in target_list^ {
		if id == block_id {
			index_to_replace = i
			break
		}
	}

	if index_to_replace != -1 {
		// Remove the block ID
		ordered_remove(target_list, index_to_replace)

		// Insert children at the original index, shifting subsequent items
		for child_id, i in block.children {
			inject_at(target_list, index_to_replace + i, child_id)
		}
	}

	// Cleanup memory
	delete(block.children)
	delete_key(&store.blocks, block_id)

	return true
}

block_content_len :: proc(state: ^Global_State, block_id: Block_ID) -> int {
	pane := state.window.panes[CURRENT_PANE_INDEX]
	if pane.blocks == nil {return 0}
	block, ok := pane.blocks.blocks[block_id]
	if !ok {return 0}
	switch d in block.data {
	case BlockText:
		return len(strings.to_string(d.content))
	case BlockHeading:
		return len(strings.to_string(d.content))
	case BlockTodo:
		return len(strings.to_string(d.content))
	}
	return 0
}

update_content :: proc(store: ^BlockStore, id: Block_ID, new_text: string) {
	if block, ok := &store.blocks[id]; ok {

		switch _ in block.data {

		case BlockText:
			if data_ptr, ok := &block.data.(BlockText); ok {
				strings.builder_reset(&data_ptr.content)
				strings.write_string(&data_ptr.content, new_text)
			}

		case BlockHeading:
			if data_ptr, ok := &block.data.(BlockHeading); ok {
				strings.builder_reset(&data_ptr.content)
				strings.write_string(&data_ptr.content, new_text)
			}

		case BlockTodo:
			if data_ptr, ok := &block.data.(BlockTodo); ok {
				strings.builder_reset(&data_ptr.content)
				strings.write_string(&data_ptr.content, new_text)
			}

		case:
			return
		}
	}
}

remove_id_from_array :: proc(array: ^[dynamic]Block_ID, target: Block_ID) {
	for id, index in array {
		if id == target {
			ordered_remove(array, index)
			break
		}
	}
}

list_page_files :: proc() -> [dynamic]string {
	home := os.get_env("HOME")
	dir := strings.concatenate({home, File_Dir})

	fmt.println(dir)

	fd, err := os.open(dir, os.O_RDONLY)
	files: [dynamic]string

	defer delete(dir)

	if err == nil {
		iter, err := os.read_dir(fd, -1)
		if err == nil {
			for f in iter {
				append(&files, strings.clone(f.name))
			}
		}
		os.file_info_slice_delete(iter)
	}

	return files
}


//// Input ////
// UP/DOWN navigate by position in root_order, not by block ID.
move_cursor :: proc(state: ^Global_State, key: rl.KeyboardKey) {
	pane := state.window.panes[CURRENT_PANE_INDEX]
	if pane.blocks == nil {return}
	root := pane.blocks.root_order

	#partial switch key {
	case .UP:
		for id, i in root {
			if id == state.cursor.block_id && i > 0 {
				state.cursor.block_id = root[i - 1]
				state.cursor.char_offset = clamp(
					state.cursor.char_offset,
					0,
					block_content_len(state, state.cursor.block_id),
				)
				break
			}
		}
	case .DOWN:
		for id, i in root {
			if id == state.cursor.block_id && i < len(root) - 1 {
				state.cursor.block_id = root[i + 1]
				state.cursor.char_offset = clamp(
					state.cursor.char_offset,
					0,
					block_content_len(state, state.cursor.block_id),
				)
				break
			}
		}
	case .LEFT:
		state.cursor.char_offset = max(0, state.cursor.char_offset - 1)
	case .RIGHT:
		state.cursor.char_offset = min(
			block_content_len(state, state.cursor.block_id),
			state.cursor.char_offset + 1,
		)
	}
}

handle_input :: proc(state: ^Global_State) {
	dt := rl.GetFrameTime()
	rep := &state.cursor.key_repeat_state
	// New Pane
	if rl.IsKeyPressed(.N) && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) {
		fmt.println("New Pane")
		append(&state.window.panes, Pane{})
		CURRENT_PANE_INDEX = len(state.window.panes) - 1
		page_id := create_page(&state.store)
		create_block(state.store.pages[page_id].store, .Text)
		load_page(state, page_id)
	}
	// Save Page
	if rl.IsKeyPressed(.S) && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) {
		pane := state.window.panes[CURRENT_PANE_INDEX]
		if page := get_page(&state.store, pane.page_id); page != nil {
			save_page(page)
			fmt.println("Saved page", pane.page_id)
		}
	}
	cursor_keys := [4]rl.KeyboardKey{.LEFT, .RIGHT, .UP, .DOWN}
	for k in cursor_keys {
		if rl.IsKeyPressed(k) {
			move_cursor(state, k)
			rep.held_key = k
			rep.timer = rep.initial_delay
			break
		}
	}

	if rl.IsKeyPressed(.BACKSPACE) {
		pane := state.window.panes[CURRENT_PANE_INDEX]
		if pane.blocks != nil {
			if block_ptr, ok := &pane.blocks.blocks[state.cursor.block_id]; ok {
				if data_ptr, ok := &block_ptr.data.(BlockText); ok {
					if state.cursor.char_offset > 0 {
						ordered_remove(&data_ptr.content.buf, state.cursor.char_offset - 1)
						state.cursor.char_offset -= 1
					} else {
						// at offset 0: merge current block's content into the previous block
						current_index := -1
						for id, i in pane.blocks.root_order {
							if id == state.cursor.block_id {
								current_index = i
								break
							}
						}
						if current_index > 0 {
							prev_id := pane.blocks.root_order[current_index - 1]
							if prev_ptr, ok := &pane.blocks.blocks[prev_id]; ok {
								if prev_data, ok := &prev_ptr.data.(BlockText); ok {
									prev_len := len(strings.to_string(prev_data.content))
									strings.write_string(
										&prev_data.content,
										strings.to_string(data_ptr.content),
									)
									ordered_remove(&pane.blocks.root_order, current_index)
									delete_key(&pane.blocks.blocks, state.cursor.block_id)
									state.cursor.block_id = prev_id
									state.cursor.char_offset = prev_len
								}
							}
						}
					}
				}
			}
		}
	}

	if rl.IsKeyPressed(.DELETE) {
		pane := state.window.panes[CURRENT_PANE_INDEX]
		if pane.blocks != nil {
			if block_ptr, ok := &pane.blocks.blocks[state.cursor.block_id]; ok {
				if data_ptr, ok := &block_ptr.data.(BlockText); ok {
					if state.cursor.char_offset < len(data_ptr.content.buf) {
						ordered_remove(&data_ptr.content.buf, state.cursor.char_offset)
					} else {
						// at end of block: pull next block's content into this one and remove it
						current_index := -1
						for id, i in pane.blocks.root_order {
							if id == state.cursor.block_id {
								current_index = i
								break
							}
						}
						if current_index != -1 && current_index < len(pane.blocks.root_order) - 1 {
							next_id := pane.blocks.root_order[current_index + 1]
							if next_ptr, ok := &pane.blocks.blocks[next_id]; ok {
								if next_data, ok := &next_ptr.data.(BlockText); ok {
									strings.write_string(
										&data_ptr.content,
										strings.to_string(next_data.content),
									)
									ordered_remove(&pane.blocks.root_order, current_index + 1)
									delete_key(&pane.blocks.blocks, next_id)
								}
							}
						}
					}
				}
			}
		}
	}

	if rl.IsKeyPressed(.ENTER) {
		pane := state.window.panes[CURRENT_PANE_INDEX]
		if pane.blocks != nil {
			// 1. Grab and remove text after cursor from the current block
			cut_text: string
			if block_ptr, ok := &pane.blocks.blocks[state.cursor.block_id]; ok {
				if data_ptr, ok := &block_ptr.data.(BlockText); ok {
					content := strings.to_string(data_ptr.content)
					if state.cursor.char_offset < len(content) {
						cut_text = strings.clone(
							content[state.cursor.char_offset:],
							context.temp_allocator,
						)
						resize(&data_ptr.content.buf, state.cursor.char_offset)
					}
				}
			}

			// 2. Find current position and create the new block
			current_index := -1
			for id, i in pane.blocks.root_order {
				if id == state.cursor.block_id {
					current_index = i
					break
				}
			}
			new_id := create_block(pane.blocks, .Text)

			// 3. Reposition new block to right after current block
			if current_index != -1 {
				last := len(pane.blocks.root_order) - 1
				if current_index + 1 < last {
					ordered_remove(&pane.blocks.root_order, last)
					inject_at(&pane.blocks.root_order, current_index + 1, new_id)
				}
			}

			// 4. Write cut text into new block at position 0
			if cut_text != "" {
				if block_ptr, ok := &pane.blocks.blocks[new_id]; ok {
					if data_ptr, ok := &block_ptr.data.(BlockText); ok {
						strings.write_string(&data_ptr.content, cut_text)
					}
				}
			}

			state.cursor.block_id = new_id
			state.cursor.char_offset = 0
		}
	}

	if rl.IsKeyPressed(.TAB) && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) {
		fmt.printf("Switched Pane: %i -> ", CURRENT_PANE_INDEX)
		if len(state.window.panes) - 1 > CURRENT_PANE_INDEX {
			CURRENT_PANE_INDEX += 1
		} else {
			CURRENT_PANE_INDEX = 0
		}
		fmt.println(CURRENT_PANE_INDEX)

		// Reset cursor to first block of the new pane
		new_pane := state.window.panes[CURRENT_PANE_INDEX]
		if new_pane.blocks != nil && len(new_pane.blocks.root_order) > 0 {
			state.cursor.block_id = new_pane.blocks.root_order[0]
		} else {
			state.cursor.block_id = 0
		}
		state.cursor.char_offset = 0
	}

	for {
		ch := rl.GetCharPressed()
		if ch == 0 {break}
		pane := state.window.panes[CURRENT_PANE_INDEX]
		if pane.blocks == nil {continue}
		if block_ptr, ok := &pane.blocks.blocks[state.cursor.block_id]; ok {
			if data_ptr, ok := &block_ptr.data.(BlockText); ok {
				inject_at(&data_ptr.content.buf, state.cursor.char_offset, u8(ch))
				state.cursor.char_offset += 1
			}
		}
	}

	// drive key repeat while a cursor key is held
	if rep.held_key != nil && rl.IsKeyDown(rep.held_key) {
		rep.timer -= dt
		if rep.timer <= 0 {
			move_cursor(state, rep.held_key)
			rep.timer = rep.repeat_delay
		}
	} else {
		rep.held_key = nil
	}
}

render_ui :: proc(state: ^Global_State) {
	draw_pos: i32 = 0
	window_height := rl.GetScreenHeight()
	window_width := rl.GetScreenWidth()
	font_size: f32 = 24
	line_spacing: f32 = 4
	if DEBUG do rl.DrawFPS(0, 0)

	//---- Panes -----
	pane_count := i32(max(len(state.window.panes), 1))
	for pane, pane_index in state.window.panes {
		pane_width := window_width / pane_count

		// Pane Separator
		rl.DrawLine(
			draw_pos,
			0 + Default_Padding,
			draw_pos,
			window_height - Default_Padding,
			rl.ColorBrightness(Gruvbox.panel, .1),
		)

		draw_pos += 1
		draw_y: f32 = 8

		if pane.blocks != nil && len(pane.blocks.root_order) > 0 {
			for block_id in pane.blocks.root_order {
				block := pane.blocks.blocks[block_id]
				content: string
				switch d in block.data {
				case BlockText:
					content = strings.to_string(d.content)
				case BlockHeading:
					content = strings.to_string(d.content)
				case BlockTodo:
					content = strings.to_string(d.content)
				case:
					continue
				}

				cstr := strings.clone_to_cstring(content, context.temp_allocator)

				rl.DrawTextEx(
					state.window.font,
					cstr,
					{f32(draw_pos + Default_Padding), draw_y},
					font_size,
					1,
					Gruvbox.text,
				)

				if block_id == state.cursor.block_id && pane_index == CURRENT_PANE_INDEX {
					offset := clamp(state.cursor.char_offset, 0, len(content))
					// measure the prefix up to the cursor to find its x position
					prefix := content[:offset]
					prefix_cstr := strings.clone_to_cstring(prefix, context.temp_allocator)
					text_size := rl.MeasureTextEx(state.window.font, prefix_cstr, font_size, 1)

					cursor_x := f32(draw_pos + Default_Padding) + text_size.x
					cursor_y := draw_y

					rl.DrawRectangle(i32(cursor_x), i32(cursor_y), 2, i32(font_size), Gruvbox.text)
				}
				draw_y += font_size + line_spacing
			}
		}
		draw_pos += pane_width

	}
}

main :: proc() {
	window := Window_State {
		size_x     = 1280,
		size_y     = 720,
		target_fps = 60,
		panes      = make([dynamic]Pane),
	}

	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(window.size_x, window.size_y, "Synapse - Note Taker")
	rl.SetTargetFPS(window.target_fps)

	window.font = rl.LoadFontEx("things/fonts/JetBrainsMono-Regular.ttf", 32, nil, 0)

	state := Global_State {
		running = true,
		store = init_store(),
		debug = DEBUG,
		window = window,
		cursor = {key_repeat_state = {initial_delay = 0.3, repeat_delay = 0.05}},
	}

	append(&state.window.panes, Pane{})
	CURRENT_PANE_INDEX = 0
	page_id := create_page(&state.store)
	create_block(state.store.pages[page_id].store, .Text)
	load_page(&state, page_id)

	fmt.println(list_page_files())

	for !rl.WindowShouldClose() && state.running {
		handle_input(&state)
		rl.BeginDrawing()
		rl.ClearBackground(Gruvbox.bg)
		render_ui(&state)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	rl.CloseWindow()
}
