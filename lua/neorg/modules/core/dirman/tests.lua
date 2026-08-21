local tests = require("neorg.tests")
local Path = require("pathlib")

describe("core.dirman tests", function()
    local dirman = tests
        .neorg_with("core.dirman", {
            workspaces = {
                test = "./test-workspace",
            },
        }).modules
        .get_module("core.dirman")

    describe("workspace-related functions", function()
        it("properly expands workspace paths", function()
            assert.same(dirman.get_workspaces(), {
                default = Path.cwd(),
                test = Path.cwd() / "test-workspace",
            })
        end)

        it("properly sets and retrieves workspaces", function()
            assert.is_true(dirman.set_workspace("test"))

            assert.equal(dirman.get_current_workspace()[1], "test")
        end)

        it("properly creates and writes files", function()
            local ws_path = (Path.cwd() / "test-workspace")

            dirman.create_file("example-file", "test", {
                no_open = true,
            })

            finally(function()
                vim.fn.delete(ws_path:tostring(), "rf")
            end)

            assert.equal(vim.fn.filereadable((ws_path / "example-file.norg"):tostring()), 1)
        end)
    end)

    describe("auto_index and index generation", function()
        local ws_path = Path.cwd() / "test-workspace-index"

        after_each(function()
            vim.fn.delete(ws_path:tostring(), "rf")
        end)

        it("generates directory-only tree in root and 1-level index in subdirectories", function()
            local dirman_module = tests
                .neorg_with("core.dirman", {
                    workspaces = {
                        idx_test = ws_path:tostring(),
                    },
                    auto_index = {
                        enabled = true,
                        update_on_save = true,
                        no_index_dirs = { "journal" },
                    },
                }).modules
                .get_module("core.dirman")

            dirman_module.set_workspace("idx_test")

            -- Create nested file structure including journal
            dirman_module.create_file("root-note", "idx_test", { no_open = true })
            dirman_module.create_file("sub/nested-note", "idx_test", { no_open = true })
            dirman_module.create_file("sub/deep/deep-note", "idx_test", { no_open = true })
            dirman_module.create_file("journal/2026/08/21", "idx_test", { no_open = true })

            assert.equal(vim.fn.filereadable((ws_path / "index.norg"):tostring()), 1)
            assert.equal(vim.fn.filereadable((ws_path / "sub" / "index.norg"):tostring()), 1)
            assert.equal(vim.fn.filereadable((ws_path / "sub" / "deep" / "index.norg"):tostring()), 1)
            -- journal subdirectories should NOT have auto-generated indices
            assert.equal(vim.fn.filereadable((ws_path / "journal" / "index.norg"):tostring()), 0)
            assert.equal(vim.fn.filereadable((ws_path / "journal" / "2026" / "index.norg"):tostring()), 0)

            -- Check root index.norg: has root-note and subdirectories down to index.norg, but NOT leaf notes of subdirectories
            local root_idx = ws_path / "index.norg"
            local rf = io.open(root_idx:tostring(), "r")
            assert.is_not_nil(rf)
            local root_content = rf:read("*a")
            rf:close()

            assert.is_truthy(root_content:find("%- {:root%-note:}%[root%-note%]"))
            assert.is_truthy(root_content:find("%- {:sub/index:}%[sub%]"))
            assert.is_truthy(root_content:find("%-%- {:sub/deep/index:}%[deep%]"))
            assert.is_truthy(root_content:find("%- {:journal/index:}%[journal%]"))
            assert.is_falsy(root_content:find("nested%-note"))
            assert.is_falsy(root_content:find("deep%-note"))
            assert.is_falsy(root_content:find("2026"))

            -- Check sub/index.norg content: has direct note and 1 level down to deep/index
            local sub_idx = ws_path / "sub" / "index.norg"
            local sf = io.open(sub_idx:tostring(), "r")
            assert.is_not_nil(sf)
            local sub_content = sf:read("*a")
            sf:close()

            assert.is_truthy(sub_content:find("%* Index of sub"))
            assert.is_truthy(sub_content:find("%- {:nested%-note:}%[nested%-note%]"))
            assert.is_truthy(sub_content:find("%- {:deep/index:}%[deep%]"))
            -- Should NOT list deep-note in sub/index.norg
            assert.is_falsy(sub_content:find("deep%-note"))

            -- Check sub/deep/index.norg content: has direct note deep-note
            local deep_idx = ws_path / "sub" / "deep" / "index.norg"
            local df = io.open(deep_idx:tostring(), "r")
            assert.is_not_nil(df)
            local deep_content = df:read("*a")
            df:close()

            assert.is_truthy(deep_content:find("%* Index of sub/deep"))
            assert.is_truthy(deep_content:find("%- {:deep%-note:}%[deep%-note%]"))
        end)
    end)
end)
