package main

import "core:fmt"
import "core:mem"
import "core:strings"
// Data Types
Block_ID :: distinct u64
Page_ID :: u64

BlockType :: enum {
	Text,
	Todo,
	Heading,
}

// Blocks
BlockText :: struct {
	content: string,
}

BlockTodo :: struct {
	content: string,
	checked: bool,
}

BlockHeading :: struct {
	content: string,
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
	root_order: [dynamic]Block_ID,
	next_id:    Block_ID,
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

load_page :: proc(page_id: Page_ID) {
	// specific_arena is a block of memory just for this operation
	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 16 * mem.Megabyte))
	defer mem.arena_free_all(&arena)

	// Push the arena into the context so all implicit allocations use it
	context.allocator = mem.arena_allocator(&arena)

	// Everything allocated here (arrays, strings) lives in the arena
	// No need to manually free individual objects!
	//blocks := load_blocks_from_db(page_id)
	//render_page(blocks)
}

init_store :: proc() -> ^Page_Store {
	store := new(Page_Store)
	store.pages = make(map[Page_ID]Page)
	store.root_order = make([dynamic]Page_ID)
	store.next_id = 1
	return store
}

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
				content = "",
			}

		case .Todo:
			_data = BlockTodo {
				content = "",
				checked = false,
			}

		case .Heading:
			_data = BlockHeading {
				content = "",
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

	return new_id
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
			new_parent_id = 0 // <--- RESET PARENT TO 0
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

update_content :: proc(store: ^BlockStore, id: Block_ID, new_text: string) {
	// 1. Get the pointer to the block
	if block, ok := &store.blocks[id]; ok {

		// 2. Switch on the VALUE (block.data) to check the type.
		// This is the standard way to do a type switch.
		switch _ in block.data {

		case BlockText:
			// 3. Get the MUTABLE POINTER to the specific data variant
			if data_ptr, ok := &block.data.(BlockText); ok {
				delete(data_ptr.content)
				data_ptr.content = strings.clone(new_text)
			}

		case BlockHeading:
			if data_ptr, ok := &block.data.(BlockHeading); ok {
				delete(data_ptr.content)
				data_ptr.content = strings.clone(new_text)
			}

		case BlockTodo:
			if data_ptr, ok := &block.data.(BlockTodo); ok {
				delete(data_ptr.content)
				data_ptr.content = strings.clone(new_text)
			}

		case:
			return
		}
	}
}

remove_id_from_array :: proc(array: ^[dynamic]Block_ID, target: Block_ID) {
	for id, index in array {
		if id == target {
			// ordered_remove is slower than unordered, but essential for UI lists
			ordered_remove(array, index)
			break
		}
	}
}

test :: proc(page_store: ^Page_Store) {
	fmt.println("Running Tests")

	test_page_id := create_page(page_store)

	test_page := &page_store.pages[test_page_id]

	test_page.title = "Test Page"

	test_block_1 := create_block(test_page.store, BlockType.Text)
	test_block_2 := create_block(test_page.store, BlockType.Todo)
	test_block_3 := create_block(test_page.store, BlockType.Heading)

	fmt.printfln("Test Page ID: %v, Title: %s", test_page_id, test_page.title)
	fmt.println("--------------")

	// Count before deletion
	fmt.printfln("Pre-count: %d", len(test_page.store.root_order))

	// Write to block 1 (Pass the STORE pointer)
	update_content(test_page.store, test_block_1, "Hellope")

	// Loop check
	for block_id in test_page.store.root_order {
		block := test_page.store.blocks[block_id]
		fmt.printfln("Block_ID: %v, Content: %v", block.id, block.data)
	}

	// Error Check
	err1 := delete_block(test_page.store, test_block_1)
	err2 := delete_block(test_page.store, test_block_2)
	err3 := delete_block(test_page.store, test_block_3)

	if !err1 || !err2 || !err3 {
		fmt.println("Deletion failed")
	} else {
		fmt.println("Deletion Success")
	}

	// Count after deletion
	fmt.printfln("Post-count: %d", len(test_page.store.root_order))
}

main :: proc() {
	store := init_store()
	test(store)
}
