--[[
    file: Dirman-Utils
    summary: A set of utilities for the `core.dirman` module.
    internal: true
    ---
This internal submodule implements some basic utility functions for [`core.dirman`](@core.dirman).
Currently the only exposed API function is `expand_path`, which takes a path like `$name/my/location` and
converts `$name` into the full path of the workspace called `name`.
--]]

local Path = require("pathlib")

local neorg = require("neorg.core")
local log, modules = neorg.log, neorg.modules

local module = neorg.modules.create("core.dirman.utils")

---@class core.dirman.utils
module.public = {
    ---Resolve `$<workspace>/path/to/file` and return the real path
    ---@param path string | PathlibPath # path
    ---@param raw_path boolean? # If true, returns resolved path, otherwise, returns resolved path and append ".norg"
    ---@param host_file string | PathlibPath | nil file the link resides in, if the link is relative, this file is used instead of the current file
    ---@return PathlibPath?, boolean? # Resolved path. If path does not start with `$` or not absolute, adds relative from current file.
    expand_pathlib = function(path, raw_path, host_file)
        local relative = false
        if not host_file then
            host_file = vim.fn.expand("%:p")
        end
        local filepath = Path(path)
        -- Expand special chars like `$`
        local custom_workspace_path = filepath:match("^%$([^/\\]*)[/\\]")
        if custom_workspace_path then
            ---@type core.dirman?
            local dirman = modules.get_module("core.dirman")
            if not dirman then
                log.error(table.concat({
                    "Unable to jump to link with custom workspace: `core.dirman` is not loaded.",
                    "Please load the module in order to get workspace support.",
                }, " "))
                return
            end
            -- If the user has given an empty workspace name (i.e. `$/myfile`)
            if custom_workspace_path:len() == 0 then
                filepath = dirman.get_current_workspace()[2] / filepath:relative_to(Path("$"))
            else -- If the user provided a workspace name (i.e. `$my-workspace/myfile`)
                local workspace = dirman.get_workspace(custom_workspace_path)
                if not workspace then
                    local msg = "Unable to expand path: workspace '%s' does not exist"
                    log.warn(string.format(msg, custom_workspace_path))
                    return
                end
                filepath = workspace / filepath:relative_to(Path("$" .. custom_workspace_path))
            end
        elseif filepath:is_relative() then
            relative = true
            local this_file = Path(host_file):absolute()
            filepath = this_file:parent_assert() / filepath
        else
            filepath = filepath:absolute()
        end
        -- requested to expand norg file
        if not raw_path then
            if type(path) == "string" and (path:sub(#path) == "/" or path:sub(#path) == "\\") then
                -- if path ends with `/`, it is an invalid request!
                log.error(table.concat({
                    "Norg file location cannot point to a directory.",
                    string.format("Current link points to '%s'", path),
                    "which ends with a `/`.",
                }, " "))
                return
            end
            filepath = filepath:add_suffix(".norg")
        end
        return filepath, relative
    end,

    ---Call attempt to edit a file, catches and suppresses the error caused by a swap file being
    ---present. Re-raises other errors via log.error
    ---@param path string | PathlibPath
    edit_file = function(path)
        local ok, err = pcall(vim.cmd.edit, tostring(path))
        if not ok then
            -- Vim:E325 is the swap file error, in which case, a lengthy message already shows to
            -- the user, and we don't have to crash out of this function (which creates a long and
            -- misleading error message).
            if err and not err:match("Vim:E325") then
                log.error("Failed to edit file %s. Error:\n%s"):format(path, err)
            end
        end
    end,

    ---Resolve `$<workspace>/path/to/file` and return the real path
    -- NOTE: Use `expand_pathlib` which returns a PathlibPath object instead.
    ---
    ---\@deprecate Use `expand_pathlib` which returns a PathlibPath object instead. TODO: deprecate this <2024-03-27>
    ---@param path string|PathlibPath # path
    ---@param raw_path boolean? # If true, returns resolved path, otherwise, returns resolved path and append ".norg"
    ---@return string? # Resolved path. If path does not start with `$` or not absolute, adds relative from current file.
    expand_path = function(path, raw_path)
        local res = module.public.expand_pathlib(path, raw_path)
        return res and res:tostring() or nil
    end,

    --- Extracts title from a .norg file (via @document.meta, first heading, or fallback to basename)
    ---@param filepath string|PathlibPath
    ---@return string
    get_file_title = function(filepath)
        local path_str = tostring(filepath)
        local bufnr = vim.fn.bufnr(path_str)
        local lines = nil

        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
        else
            local f = io.open(path_str, "r")
            if f then
                lines = {}
                for _ = 1, 50 do
                    local line = f:read("*line")
                    if not line then
                        break
                    end
                    table.insert(lines, line)
                end
                f:close()
            end
        end

        if lines and #lines > 0 then
            local in_meta = false
            for _, line in ipairs(lines) do
                if line:match("^%s*@document%.meta%s*$") then
                    in_meta = true
                elseif in_meta then
                    if line:match("^%s*@end%s*$") then
                        in_meta = false
                    else
                        local meta_title = line:match("^%s*title%s*:%s*(.+)%s*$")
                        if meta_title and meta_title ~= "" then
                            meta_title = meta_title:gsub('^["\']', ""):gsub('["\']$', "")
                            meta_title = vim.trim(meta_title)
                            if meta_title ~= "" then
                                return meta_title:gsub("%[", "("):gsub("%]", ")")
                            end
                        end
                    end
                end
            end

            for _, line in ipairs(lines) do
                local heading = line:match("^%s*%*+%s+(.+)%s*$")
                if heading and heading ~= "" then
                    heading = vim.trim(heading)
                    if heading ~= "" then
                        return heading:gsub("%[", "("):gsub("%]", ")")
                    end
                end
            end
        end

        local basename = vim.fs.basename(path_str):gsub("%.norg$", "")
        return basename
    end,

    --- Recursively scans a workspace and finds all directories that contain .norg files
    ---@param ws_root PathlibPath
    ---@param exclude_dirs string[]? list of directory names to exclude (e.g. { ".git", ".neorg" })
    ---@param index_name string? name of the index file (default "index.norg")
    ---@param no_index_dirs string[]? list of directory names not to auto-generate index files in (default { "journal" })
    ---@return PathlibPath[], table<string, boolean>, table<string, boolean>, table<string, boolean> all_dirs, dir_has_norg_map, excluded_set, no_index_set
    scan_workspace_directories = function(ws_root, exclude_dirs, index_name, no_index_dirs)
        index_name = index_name or "index.norg"
        local excluded_set = {}
        for _, ex in ipairs(exclude_dirs or { ".git", ".neorg" }) do
            excluded_set[ex] = true
        end

        local no_index_set = {}
        for _, ni in ipairs(no_index_dirs or { "journal" }) do
            no_index_set[ni] = true
        end

        local dir_has_norg = {}
        local all_dirs = {}

        local function scan(dir)
            local has_direct_norg = false
            local subdirs = {}

            local ok, dir_iter = pcall(vim.fs.dir, dir:tostring())
            if not ok or not dir_iter then
                return false
            end

            for name, type in dir_iter do
                if not excluded_set[name] and not vim.startswith(name, ".") then
                    local full = dir / name
                    if type == "directory" then
                        table.insert(subdirs, full)
                    elseif type == "file" and vim.endswith(name, ".norg") then
                        if name ~= index_name then
                            has_direct_norg = true
                        else
                            has_direct_norg = true
                        end
                    end
                end
            end

            local has_sub_with_norg = false
            for _, sub in ipairs(subdirs) do
                local s_name = vim.fs.basename(sub:tostring())
                if no_index_set[s_name] then
                    dir_has_norg[sub:tostring()] = true
                    has_sub_with_norg = true
                else
                    local sub_has = scan(sub)
                    if sub_has then
                        has_sub_with_norg = true
                    end
                end
            end

            local has_any_norg = has_direct_norg or has_sub_with_norg
            dir_has_norg[dir:tostring()] = has_any_norg

            local curr_name = vim.fs.basename(dir:tostring())
            if dir:tostring() ~= ws_root:tostring() and not no_index_set[curr_name] then
                local has_direct_notes = false
                local ok2, iter2 = pcall(vim.fs.dir, dir:tostring())
                if ok2 and iter2 then
                    for name, type in iter2 do
                        if
                            type == "file"
                            and vim.endswith(name, ".norg")
                            and name ~= index_name
                            and not vim.startswith(name, ".")
                        then
                            has_direct_notes = true
                            break
                        end
                    end
                end

                if has_direct_notes or has_sub_with_norg then
                    table.insert(all_dirs, dir)
                end
            end

            return has_any_norg
        end

        scan(ws_root)
        table.insert(all_dirs, ws_root)
        dir_has_norg[ws_root:tostring()] = true

        return all_dirs, dir_has_norg, excluded_set, no_index_set
    end,

    --- Generates the lines for an index.norg file in dir_path
    ---@param dir_path PathlibPath
    ---@param ws_root PathlibPath
    ---@param dir_has_norg_map table<string, boolean>
    ---@param excluded_set table<string, boolean>
    ---@param no_index_set table<string, boolean>
    ---@param opts table?
    ---@return string[]
    generate_index_content = function(dir_path, ws_root, dir_has_norg_map, excluded_set, no_index_set, opts)
        opts = opts or {}
        local index_name = opts.index or "index.norg"
        local index_base = index_name:gsub("%.norg$", "")
        local is_root = (dir_path:tostring() == ws_root:tostring())
        local lines = {}

        local heading
        if opts.format_heading then
            heading = opts.format_heading(dir_path, ws_root, is_root)
        elseif is_root then
            heading = "* Index"
        else
            local rel_path = dir_path:relative_to(ws_root):tostring("/")
            heading = "* Index of " .. rel_path
        end

        table.insert(lines, heading)
        table.insert(lines, "")

        local function get_direct_files(dir)
            local files = {}
            local ok, dir_iter = pcall(vim.fs.dir, dir:tostring())
            if not ok or not dir_iter then
                return files
            end

            for name, type in dir_iter do
                if
                    type == "file"
                    and vim.endswith(name, ".norg")
                    and name ~= index_name
                    and not vim.startswith(name, ".")
                then
                    table.insert(files, dir / name)
                end
            end
            table.sort(files, function(a, b)
                return a:tostring():lower() < b:tostring():lower()
            end)
            return files
        end

        local function get_direct_subdirs(dir)
            local subdirs = {}
            local ok, dir_iter = pcall(vim.fs.dir, dir:tostring())
            if not ok or not dir_iter then
                return subdirs
            end

            for name, type in dir_iter do
                if type == "directory" and not excluded_set[name] and not vim.startswith(name, ".") then
                    local sub = dir / name
                    if dir_has_norg_map[sub:tostring()] then
                        table.insert(subdirs, sub)
                    end
                end
            end
            table.sort(subdirs, function(a, b)
                return a:tostring():lower() < b:tostring():lower()
            end)
            return subdirs
        end

        if is_root then
            -- Root index:
            -- 1. Direct files at the root level (prefixed by **)
            local direct_files = get_direct_files(dir_path)
            for _, f in ipairs(direct_files) do
                local rel = f:relative_to(dir_path):tostring("/"):gsub("%.norg$", "")
                local title = module.public.get_file_title(f)
                table.insert(lines, "** {:" .. rel .. ":}[" .. title .. "]")
            end

            -- 2. Recursive directory tree linking to index.norg files only (depth 1 starts with **, then ***, etc.)
            local function render_root_tree(curr_dir, depth)
                local subdirs = get_direct_subdirs(curr_dir)
                for _, s in ipairs(subdirs) do
                    local s_name = vim.fs.basename(s:tostring())
                    local rel_index = s:relative_to(dir_path):tostring("/") .. "/" .. index_base
                    local prefix = string.rep("*", depth + 1) .. " "
                    table.insert(lines, prefix .. "{:" .. rel_index .. ":}[" .. s_name .. "]")

                    if not no_index_set[s_name] then
                        render_root_tree(s, depth + 1)
                    end
                end
            end

            render_root_tree(dir_path, 1)
        else
            -- Subdirectory index:
            -- 1. Direct files in this directory (prefixed by **)
            local direct_files = get_direct_files(dir_path)
            for _, f in ipairs(direct_files) do
                local rel = f:relative_to(dir_path):tostring("/"):gsub("%.norg$", "")
                local title = module.public.get_file_title(f)
                table.insert(lines, "** {:" .. rel .. ":}[" .. title .. "]")
            end

            -- 2. Down 1 level to direct subdirectories' index.norg (prefixed by ***)
            local direct_subdirs = get_direct_subdirs(dir_path)
            for _, s in ipairs(direct_subdirs) do
                local s_name = vim.fs.basename(s:tostring())
                local rel_index = s_name .. "/" .. index_base
                table.insert(lines, "*** {:" .. rel_index .. ":}[" .. s_name .. "]")
            end
        end

        return lines
    end,

    --- Writes content to an index file, safely updating open buffer if loaded
    ---@param index_path PathlibPath
    ---@param lines string[]
    ---@return boolean was_modified returns true if file was created or content changed
    write_index_file = function(index_path, lines)
        local path_str = tostring(index_path)
        local content_str = table.concat(lines, "\n") .. "\n"

        local bufnr = vim.fn.bufnr(path_str)
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local current_content = table.concat(current_lines, "\n") .. "\n"
            if current_content ~= content_str then
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                vim.api.nvim_buf_call(bufnr, function()
                    vim.cmd("silent! noautocmd write")
                end)
                return true
            end
            return false
        end

        if index_path:exists() then
            local f = io.open(path_str, "r")
            if f then
                local existing = f:read("*a")
                f:close()
                if existing == content_str then
                    return false
                end
            end
        end

        index_path:parent_assert():mkdir(Path.const.o755, true)
        local f = io.open(path_str, "w")
        if f then
            f:write(content_str)
            f:close()
            return true
        else
            log.error("Unable to write index file: " .. path_str)
            return false
        end
    end,

    --- Generates/updates index files for the root workspace and all subdirectories containing .norg files
    ---@param ws_root PathlibPath
    ---@param opts table?
    ---@return number modified_count, PathlibPath[] all_dirs
    generate_all_indices = function(ws_root, opts)
        opts = opts or {}
        local index_name = opts.index or "index.norg"
        local all_dirs, dir_has_norg_map, excluded_set, no_index_set =
            module.public.scan_workspace_directories(ws_root, opts.exclude_dirs, index_name, opts.no_index_dirs)

        local modified_count = 0
        for _, dir in ipairs(all_dirs) do
            local lines =
                module.public.generate_index_content(dir, ws_root, dir_has_norg_map, excluded_set, no_index_set, opts)
            local index_file = dir / index_name
            local modified = module.public.write_index_file(index_file, lines)
            if modified then
                modified_count = modified_count + 1
            end
        end

        return modified_count, all_dirs
    end,

    --- Generates/updates index file for a single directory
    ---@param dir_path PathlibPath
    ---@param ws_root PathlibPath
    ---@param opts table?
    ---@return boolean was_modified
    generate_index_for_dir = function(dir_path, ws_root, opts)
        opts = opts or {}
        local index_name = opts.index or "index.norg"
        local all_dirs, dir_has_norg_map, excluded_set, no_index_set =
            module.public.scan_workspace_directories(ws_root, opts.exclude_dirs, index_name, opts.no_index_dirs)

        local lines =
            module.public.generate_index_content(dir_path, ws_root, dir_has_norg_map, excluded_set, no_index_set, opts)
        local index_file = dir_path / index_name
        return module.public.write_index_file(index_file, lines)
    end,

    --- Expands ~ or environment variables in a path to an absolute PathlibPath
    ---@param path string|PathlibPath?
    ---@return PathlibPath?
    expand_tilde = function(path)
        if not path then
            return nil
        end
        local path_str = tostring(path)
        if vim.startswith(path_str, "~") then
            local home = vim.loop.os_homedir() or vim.fn.expand("~")
            path_str = path_str:gsub("^~", home)
        end
        return Path(path_str):resolve():to_absolute()
    end,

    --- Recursively gets all subdirectories under root_dir (including root_dir itself)
    ---@param root_dir PathlibPath
    ---@param exclude_dirs string[]?
    ---@return PathlibPath[]
    get_subdirectories = function(root_dir, exclude_dirs)
        local ex_set = {}
        for _, ex in ipairs(exclude_dirs or { ".git", ".neorg" }) do
            ex_set[ex] = true
        end

        local dirs = { root_dir }

        local function traverse(curr)
            local ok, iter = pcall(vim.fs.dir, curr:tostring())
            if not ok or not iter then
                return
            end

            local subs = {}
            for name, type in iter do
                if type == "directory" and not ex_set[name] and not vim.startswith(name, ".") then
                    local full = curr / name
                    table.insert(subs, full)
                end
            end

            table.sort(subs, function(a, b)
                return a:tostring():lower() < b:tostring():lower()
            end)

            for _, s in ipairs(subs) do
                table.insert(dirs, s)
                traverse(s)
            end
        end

        traverse(root_dir)
        return dirs
    end,

    --- Prompts the user to pick a directory using fzf-lua, telescope, or vim.ui.select
    ---@param dir_list PathlibPath[]
    ---@param root_dir PathlibPath
    ---@param opts table?
    ---@param callback fun(chosen_dir: PathlibPath)
    pick_directory = function(dir_list, root_dir, opts, callback)
        opts = opts or {}
        local picker_pref = opts.picker or "auto"
        local prompt_text = opts.prompt or "Select directory for dated note: "

        local entries = {}
        local entry_to_dir = {}
        for _, d in ipairs(dir_list) do
            local display = (d:tostring() == root_dir:tostring()) and "." or d:relative_to(root_dir):tostring("/")
            table.insert(entries, display)
            entry_to_dir[display] = d
        end

        -- 1. Try fzf-lua if requested or auto
        if picker_pref == "fzf-lua" or picker_pref == "auto" then
            local fzf_ok, fzf = pcall(require, "fzf-lua")
            if fzf_ok and fzf.fzf_exec then
                fzf.fzf_exec(entries, {
                    prompt = prompt_text,
                    actions = {
                        ["default"] = function(selected)
                            if selected and #selected > 0 then
                                local choice = selected[1]
                                local chosen = entry_to_dir[choice] or (root_dir / choice)
                                callback(chosen)
                            end
                        end,
                    },
                })
                return
            end
        end

        -- 2. Try telescope if requested or auto
        if picker_pref == "telescope" or picker_pref == "auto" then
            local tele_ok, pickers = pcall(require, "telescope.pickers")
            local finders_ok, finders = pcall(require, "telescope.finders")
            local conf_ok, conf = pcall(require, "telescope.config")
            local actions_ok, actions = pcall(require, "telescope.actions")
            local action_state_ok, action_state = pcall(require, "telescope.actions.state")

            if tele_ok and finders_ok and actions_ok and action_state_ok then
                pickers
                    .new({}, {
                        prompt_title = prompt_text,
                        finder = finders.new_table({
                            results = entries,
                        }),
                        sorter = conf_ok and conf.values.generic_sorter({}) or nil,
                        attach_mappings = function(prompt_bufnr)
                            actions.select_default:replace(function()
                                actions.close(prompt_bufnr)
                                local selection = action_state.get_selected_entry()
                                if selection then
                                    local choice = selection[1] or selection.value
                                    local chosen = entry_to_dir[choice] or (root_dir / choice)
                                    callback(chosen)
                                end
                            end)
                            return true
                        end,
                    })
                    :find()
                return
            end
        end

        -- 3. Fallback to standard vim.ui.select
        vim.ui.select(entries, {
            prompt = prompt_text,
            format_item = function(item)
                return item == "." and ". (Root: " .. vim.fs.basename(root_dir:tostring()) .. ")" or item
            end,
        }, function(choice)
            if choice then
                local chosen = entry_to_dir[choice] or (root_dir / choice)
                callback(chosen)
            end
        end)
    end,

    --- Creates and opens a dated .norg file inside dir_path
    ---@param dir_path PathlibPath
    ---@param opts table?
    ---@return PathlibPath note_file, boolean is_new
    create_dated_note = function(dir_path, opts)
        opts = opts or {}
        local date_format = opts.date_format or "%Y-%m-%d"
        local date_str = vim.fn.strftime(date_format)
        local extension = opts.extension or ".norg"
        if not vim.startswith(extension, ".") then
            extension = "." .. extension
        end

        local filename = date_str .. extension
        local note_file = dir_path / filename

        -- Ensure directory exists
        dir_path:mkdir(Path.const.o755 + 4 * math.pow(8, 4), true)

        local is_new = not note_file:exists()
        if is_new then
            local fd = note_file:fs_open("a", Path.const.o644, false)
            if fd then
                vim.loop.fs_close(fd)
            end
        end

        if opts.chdir then
            pcall(vim.loop.chdir, dir_path:tostring())
        end

        if not opts.no_open then
            module.public.edit_file(note_file)
        end

        return note_file, is_new
    end,
}

return module
