local fs = Deps("lib/fs")
local json = Deps("rxi/json.lua:json", "v0.1.2")
local time = Deps("lib/time")
local shellsort = Deps("third_party/shellsort")
local hw = Deps("lib/hw")

CONFIG = {
    main_display = "7FC05BBE4B398CD7430CFDAF66DDCC17",
    history_file = "/storage_display/history.json"
}

BLACK = {0, 0, 0, 1}
WHITE = {1, 1, 1, 1}
GRAY30 = {0.3, 0.3, 0.3, 1}
GRAY50 = {0.5, 0.5, 0.5, 1}
GREEN = {0, 1, 0, 1}
RED = {1, 0, 0, 1}
YELLOW = {1, 1, 0, 1}

DB = {}
DB.__index = DB
function DB:new(o)
    o = o or {
        entries = {}
    }

    for i, entry in pairs(o.entries) do
        o.entries[i] = DBEntry:new(entry)
    end

    setmetatable(o, self)
    return o
end

function DB:entry(item_type)
    if self.entries[item_type.name] == nil then
        self.entries[item_type.name] = DBEntry:new{
            item_type = {
                name = item_type.name,
                max = item_type.max
            }
        }
    end
    return self.entries[item_type.name]
end

function DB:to_json()
    return {
        entries = self.entries
    }
end

DBEntry = {}
DBEntry.__index = DBEntry
function DBEntry:new(o)
    o = o or {}
    o.item_type = o.item_type or nil
    o.count = o.count or 0
    o.storage_capacity = o.storage_capacity or 0
    setmetatable(o, self)
    return o
end

function DBEntry:record_items(count)
    self.count = self.count + count
    return self
end

function DBEntry:record_capacity(stacks)
    self.storage_capacity = self.storage_capacity + stacks * self.item_type.max
    return self
end

function DBEntry:get_fill_percent()
    return math.floor(self.count / self.storage_capacity * 100)
end

function DBEntry:to_json()
    return {
        item_type = self.item_type,
        count = self.count,
        storage_capacity = self.storage_capacity
    }
end

History = {}
History.__index = History
function History:new(o)
    o = o or {}
    o.entries = o.entries or {}

    for i, entry in pairs(o.entries) do
        o.entries[i] = HistoryEntry:new(entry)
    end

    o.retention = o.retention or 300
    o.frequency = o.frequency or 5
    setmetatable(o, self)
    return o
end

function History:record(db, duration)
    table.insert(self.entries, HistoryEntry:new{
        db = db,
        duration = duration
    })
    self:prune()
end

function History:size()
    return #self.entries
end

function History:prune()
    local cutoff = time.timestamp() - self.retention
    local i = 1
    while i <= #self.entries do
        if self.entries[i].time < cutoff then
            table.remove(self.entries, i)
        else
            i = i + 1
        end
    end
end

function History:rate_per_minute(item_type, duration)
    local oldest_i = 1
    while oldest_i < #self.entries and self.entries[oldest_i]:age() > duration do
        oldest_i = oldest_i + 1
    end
    local oldest = self.entries[oldest_i]
    local newest = self.entries[#self.entries]

    local delta = newest.db:entry(item_type).count - oldest.db:entry(item_type).count
    local elapsed_seconds = newest.time - oldest.time
    local elapsed_minutes = elapsed_seconds / 60
    return math.floor(delta / elapsed_minutes)
end

function History:time_to_next_snapshot()
    if #self.entries == 0 then
        return 0
    end
    return math.ceil(self.frequency - self:last():age())
end

function History:last()
    return self.entries[#self.entries]
end

function History:to_json()
    local entries = {}
    for _, entry in pairs(self.entries) do
        table.insert(entries, entry:to_json())
    end

    return {
        entries = entries,
        retention = self.retention,
        frequency = self.frequency
    }
end

HistoryEntry = {}
HistoryEntry.__index = HistoryEntry
function HistoryEntry:new(o)
    o = o or {}
    o.db = o.db or nil

    if o.db then
        o.db = DB:new(o.db)
    end

    o.time = o.time or time.timestamp()
    o.duration = o.duration or nil
    setmetatable(o, self)
    return o
end

function HistoryEntry:age()
    return math.floor(time.timestamp() - self.time)
end

function HistoryEntry:to_json()
    return {
        db = self.db:to_json(),
        time = self.time,
        duration = self.duration
    }
end

local function count_items(db, container)
    local inventories = container:getInventories()
    for _, inventory in pairs(inventories) do
        local db_entry = nil
        for nStack = 0, inventory.size - 1, 1 do
            local stack = inventory:getStack(nStack)
            if stack ~= nil and stack.count ~= 0 then
                if db_entry == nil then
                    db_entry = db:entry(stack.item.type)
                elseif db_entry.item_type.name ~= stack.item.type.name then
                    computer.panic("ERROR: multiple items in container " .. container.getHash() .. " inventory " ..
                                       inventory.getHash())
                end
                db_entry:record_items(stack.count)
            end
        end
        if db_entry ~= nil then
            db_entry:record_capacity(inventory.size)
        end
    end
end

TablePrinter = {}
TablePrinter.__index = TablePrinter
function TablePrinter:new(headings)
    local o = {
        headings = {
            cells = headings
        },
        rows = {},
        rowcolors = {},
        widths = {}
    }
    setmetatable(o, self)

    for i, heading in pairs(headings) do
        o.widths[i] = #heading
    end

    return o
end

function TablePrinter:sort()
    shellsort(self.rows, function(a, b)
        return a.cells[1] < b.cells[1]
    end)
end

function TablePrinter:insert(color, row)
    local row_str = {}
    for _, col in pairs(row) do
        table.insert(row_str, tostring(col))
    end

    for i, cell in pairs(row_str) do
        if self.widths[i] == nil or #cell > self.widths[i] then
            self.widths[i] = #cell
        end
    end

    table.insert(self.rows, {
        color = color,
        cells = row_str
    })
end

function TablePrinter:align_columns(row)
    local padding
    local retval = {}
    for j, cell in pairs(row) do
        padding = self.widths[j] - #cell
        table.insert(retval, string.rep(" ", padding) .. " " .. cell .. " ")
    end
    return retval
end

function TablePrinter:colors(cell, highlight)
    local x, y, width = table.unpack(cell)
    if y == 0 then
        return BLACK, WHITE
    end
    local bgcolor = BLACK
    if highlight ~= nil and highlight[2] <= #self.rows then
        local x_hit = x < highlight[1] and x + width >= highlight[1]
        local y_hit = y == highlight[2]
        if x_hit and y_hit then
            bgcolor = GRAY50
        elseif x_hit or y_hit then
            bgcolor = GRAY30
        end
    end
    return self.rows[y].color, bgcolor
end

function TablePrinter:format_row(y, highlight, row)
    local retval = {}
    local x = 1
    for _, cell in pairs(self:align_columns(row.cells)) do
        local fg, bg = self:colors({x, y, #cell}, highlight)
        table.insert(retval, {cell, fg, bg})
        x = x + #cell
    end
    return retval
end

function TablePrinter:format(highlight)
    local retval = {}
    table.insert(retval, self:format_row(0, highlight, self.headings))
    for y, row in pairs(self.rows) do
        table.insert(retval, self:format_row(y, highlight, row))
    end
    return retval
end

local function display_status(gpu, y, status)
    gpu:setForeground(table.unpack(GRAY30))
    gpu:setBackground(table.unpack(BLACK))
    gpu:setText(0, y, status)
    gpu:setForeground(table.unpack(WHITE))
end

local function display(history, highlight, gpu, status)
    local table_printer = TablePrinter:new{"NAME", "COUNT", "CAPACITY", "FILL%", "RATE@15S", "RATE@1M", "RATE@10M"}
    local width = #status

    local history_entry = history:last()
    if history_entry ~= nil then
        local db = history_entry.db
        for _, entry in pairs(db.entries) do
            local fill_percent = entry:get_fill_percent()
            local rate_10min = history:rate_per_minute(entry.item_type, 600)
            local color
            if fill_percent >= 99 then
                color = GREEN
            elseif fill_percent > 75 and rate_10min > 0 then
                color = WHITE
            elseif rate_10min > 0 then
                color = YELLOW
            else
                color = RED
            end
            table_printer:insert(color,
                {entry.item_type.name, entry.count, entry.storage_capacity, entry:get_fill_percent(),
                 string.format("%s/m", history:rate_per_minute(entry.item_type, 15)),
                 string.format("%s/m", history:rate_per_minute(entry.item_type, 60)), string.format("%s/m", rate_10min)})
        end
        table_printer:sort()

        local rows = table_printer:format(highlight)
        for _, row in pairs(rows) do
            local this_width = 0
            for _, cell in pairs(row) do
                this_width = this_width + #cell[1]
            end
            if this_width > width then
                width = this_width
            end
        end
        local height = #rows + 2
        gpu:setSize(width, height)
        gpu:setForeground(table.unpack(WHITE))
        gpu:setBackground(table.unpack(BLACK))
        gpu:fill(0, 0, width, height, "")
        for y, row in pairs(rows) do
            local x = 0
            for _, cellspec in pairs(row) do
                local cell, fg, bg = table.unpack(cellspec)
                gpu:setForeground(table.unpack(fg))
                gpu:setBackground(table.unpack(bg))
                gpu:setText(x, y - 1, cell)
                x = x + #cell
            end
        end
        display_status(gpu, height - 1, status)
    else
        display_status(gpu, 0, status)
    end

    gpu:flush()
end

local function snapshot(history, containers)
    local start = computer.millis()
    local db = DB:new()
    for _, container in pairs(containers) do
        count_items(db, container)
    end
    history:record(db, computer.millis() - start)
end

local function highlight_changed(old, new)
    if old == nil then
        return new ~= nil
    end
    if new == nil then
        return old ~= nil
    end
    return old[1] ~= new[1] or old[2] ~= new[2]
end

local function load_history()
    local content = fs.read_all(CONFIG.history_file)
    local history = History:new(json.decode(content))
    print("Loaded history from " .. CONFIG.history_file .. " with " .. history:size() .. " entries.")
    return history
end

local function main()
    local containers = component.proxy(component.findComponent(findClass("Build_StorageContainerMk2_C")))
    local gpu = hw.gpu()
    local main_display = component.proxy(CONFIG.main_display)

    local history = nil
    if fs.exists(CONFIG.history_file) then
        local status, history_or_error = pcall(load_history)
        if status then
            history = history_or_error
        else
            print("Error loading history: " .. history_or_error)
        end
    end
    if history == nil then
        history = History:new{
            retention = 900,
            frequency = 5
        }
        print("Created new history")
    end

    gpu:bindScreen(main_display)
    event.listen(gpu)

    local last_highlight = nil
    local last_time_to_next_snapshot = nil
    while true do
        local highlight = nil
        local dirty = false
        local force_update = false

        -- Process the event queue
        local e, s, x, y = event.pull(1.0)
        while e ~= nil do
            if e == "OnMouseMove" then
                highlight = {x, y}
                if highlight_changed(last_highlight, highlight) then
                    dirty = true
                    last_highlight = highlight
                end
            end
            if e == "OnMouseDown" then
                force_update = true
            end
            e, s, x, y = event.pull(0)
        end

        local time_to_next_snapshot = history:time_to_next_snapshot()
        if last_time_to_next_snapshot ~= time_to_next_snapshot then
            dirty = true
        end
        if time_to_next_snapshot <= 0 or force_update then
            snapshot(history, containers)
            last_time_to_next_snapshot = time_to_next_snapshot
            fs.mkdir_p(fs.dirname(CONFIG.history_file))
            fs.write_all(CONFIG.history_file, json.encode(history))
            dirty = true
        end

        if dirty then
            local status = string.format("Last update %ss ago (took %sms). Next update in %ss or on click.",
                history:last():age(), history:last().duration, time_to_next_snapshot)
            display(history, last_highlight, gpu, status)
        end
    end
end

return main
