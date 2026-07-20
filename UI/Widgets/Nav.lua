local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Nav.lua
-- A vertical NAVIGATION list: section labels + selectable items (optionally indented as
-- sub-items), with a single active selection (accent highlight + bar) and an onSelect callback.
-- Built ON Widgets.Grid (a 1-column grid) so it shares the one aligned layout + theming -- the
-- sidebar/tree any window needs, without each re-deriving row positioning or active state.
--   opts: items = { { key="x", label="X", indent=number } | { section="Group" }, ... }
--         onSelect = function(key)   rowHeight (30)   scroll (default false; name required if true)
--   methods: :SetItems(items)  :Select(key[, silent])  :GetSelected()
local NavW = ns.Class.new("Nav", Widgets.Grid)
function NavW:Initialize(parent, opts)
    opts = opts or {}
    NavW.super.Initialize(self, parent, {
        columns = { {} }, scroll = opts.scroll or false, name = opts.name,
        rowHeight = opts.rowHeight or 30, cellPad = opts.cellPad,
    })
    local p = self:_p()
    p.items = opts.items or {}
    p.onSelect = opts.onSelect
    p.onReselect = opts.onReselect   -- fired when the user CLICKS the already-active item (optional)
    self:_Rebuild()
end
function NavW:_Rebuild()
    local p = self:_p()
    local rows = {}
    for _, it in ipairs(p.items) do
        if it.section then
            rows[#rows + 1] = { section = it.section }
        else
            local key = it.key
            rows[#rows + 1] = {
                cells = { it.label }, indent = it.indent or 0,
                active = (key == p.selected),
                -- re-clicking the active item routes to onReselect (only on a real click, never on
                -- a programmatic Select), so callers can e.g. toggle back to a home/overview view.
                onClick = function()
                    if key == p.selected and p.onReselect then p.onReselect(key)
                    else self:Select(key) end
                end,
            }
        end
    end
    self:SetRows(rows)
end
function NavW:SetItems(items) self:_p().items = items or {}; self:_Rebuild(); return self end
function NavW:GetSelected()   return self:_p().selected end
-- Select a key: re-highlight and (unless silent) fire onSelect. No-op styling for an
-- unknown key, so callers can clear the selection with nil.
function NavW:Select(key, silent)
    local p = self:_p()
    p.selected = key
    self:_Rebuild()
    if not silent and p.onSelect then p.onSelect(key) end
    return self
end
Widgets.Nav = NavW
