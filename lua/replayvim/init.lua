-- ReplayVim -- record every edit to a buffer and replay it from empty.
--
-- Log format: a header line, then one op per line, tab separated, appended
-- in order.
--     #replayvim\tepoch\t<unix_seconds>
--     <secs_since_epoch>\t<byte_offset>\t<bytes_deleted>\t<inserted_text_escaped>
-- The epoch is when the log was first written to disk. Add it to an op's
-- seconds to get a Unix time. Byte offsets are 0-based into the whole
-- document. Replay = start from "", apply ops in order. Stored beside the
-- file as a hidden dotfile, e.g. foo.lua -> .foo.lua.replay
--
-- Older logs (no header, three fields per op) still load. Their ops have no
-- timestamp; a header is appended the next time the log is written, and ops
-- after that point are timed relative to it.
--
-- Timestamps are taken when an op is committed (see below), so a long
-- insert session is stamped when you leave insert mode, not when it began.
-- A new log is written as soon as the first real edit is committed, so the
-- epoch is that moment. The seed op (the file's contents when it was
-- opened) predates it and is stamped 0.
--
-- Permissions: the log mirrors the source file's rwx bits, so a private file
-- doesn't leave a world-readable history lying next to it. Owner-write is
-- always kept on the log, otherwise a read-only source would stop us
-- appending. Checked when the file is opened and after each write; a
-- warning is shown (once per buffer) if the log can't be chmod'ed.
--
-- How recording works:
--   on_bytes hands us (start_byte, bytes_removed, bytes_added) for every
--   change. We do NOT materialise the document -- we just widen a "dirty
--   span" of three integers. That's O(1) per keystroke regardless of file
--   size.
--
--   At a commit point (TextChanged / InsertLeave) we read back only the
--   dirty region and append ONE op. Coalescing falls out for free: a whole
--   typed sentence is one op, and type-then-backspace-then-retype collapses
--   to its net effect.
--
--   Integrity: we track the document length as an integer and compare it
--   against the buffer's real length after every commit -- an O(1) check.
--   Any disagreement triggers a corrective full-replace op, so the log can
--   drift for at most one commit before healing itself.
--
-- Commands:
--     :ReplayVimStartTracking  start recording this buffer's edits
--     :ReplayVimStopTracking   stop recording this buffer's edits
--     :ReplayVim [gap_ms]      replay this file's history in a split
--     :ReplayVimStop           halt a running replay
--     :ReplayVimTape [out]     export the history as a VHS .tape file
--     :ReplayVimCheck          validate the log, report any bad ops
--     :ReplayVimClear          delete this file's log
--
-- Tracking is off by default: nothing is recorded until you run
-- :ReplayVimStartTracking (or set auto_attach = true, see below).
--
-- Config: vim.g.replayvim = { gap_ms = 20 }   (before load)
--         require("replayvim").setup { gap_ms = 20 }

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local config = {
  gap_ms = 40,      -- ms between ops during replay
  flush_every = 16, -- ops buffered in memory before hitting disk
  log_suffix = ".replay",
  auto_attach = false, -- off by default; opt in with :ReplayVimStartTracking
}
for k, v in pairs(vim.g.replayvim or {}) do config[k] = v end

function M.setup(opts)
  for k, v in pairs(opts or {}) do config[k] = v end
end
M.config = config

local IS_WIN = vim.fn.has("win32") == 1

--------------------------------------------------------------------------
-- text model
--
-- Document text = buffer lines joined by "\n", no trailing newline.
-- An empty buffer is "". Offsets are 0-based byte offsets.
--------------------------------------------------------------------------

local function buf_text(bufnr)
  return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Document length without materialising it. nvim counts a trailing newline
-- after the final line; our model doesn't, hence the -1.
local function doc_len(bufnr)
  return api.nvim_buf_get_offset(bufnr, api.nvim_buf_line_count(bufnr)) - 1
end

-- Byte offset -> (row, col) via binary search over line offsets. O(log lines),
-- no document copy. nvim_buf_get_offset agrees with our model for line starts.
local function offset_to_rc_buf(bufnr, offset)
  local lo, hi = 0, api.nvim_buf_line_count(bufnr) - 1
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if api.nvim_buf_get_offset(bufnr, mid) <= offset then lo = mid else hi = mid - 1 end
  end
  return lo, offset - api.nvim_buf_get_offset(bufnr, lo)
end

-- Read just the bytes in [from, to) out of the buffer.
local function read_region(bufnr, from, to)
  if to <= from then return "" end
  local r1, c1 = offset_to_rc_buf(bufnr, from)
  local r2, c2 = offset_to_rc_buf(bufnr, to)
  local ok, lines = pcall(api.nvim_buf_get_text, bufnr, r1, c1, r2, c2, {})
  if not ok then return nil end
  return table.concat(lines, "\n")
end

local function offset_to_rc(text, offset)
  local row, last, i = 0, 0, 1
  while true do
    local nl = text:find("\n", i, true)
    if not nl or nl > offset then break end
    row, last, i = row + 1, nl, nl + 1
  end
  return row, offset - last
end

--------------------------------------------------------------------------
-- log io
--------------------------------------------------------------------------

local ESC = { ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
local UNESC = { ["\\"] = "\\", n = "\n", t = "\t", r = "\r" }

local function esc(s) return (s:gsub("[\\\n\t\r]", ESC)) end
local function unesc(s) return (s:gsub("\\(.)", function(c) return UNESC[c] or c end)) end

local function src_path(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return vim.fn.fnamemodify(name, ":p")
end

local function log_path(bufnr)
  local name = src_path(bufnr)
  if not name then return nil end
  local dir = vim.fn.fnamemodify(name, ":h")
  local base = vim.fn.fnamemodify(name, ":t")
  if base == "" then return nil end
  return dir .. "/." .. base .. config.log_suffix
end

local function log_exists(path)
  return uv.fs_stat(path) ~= nil
end

local function header_line(epoch)
  return string.format("#replayvim\tepoch\t%d", epoch)
end

-- Returns ops, epoch. Each op is { offset, deleted, text, secs_or_nil }.
-- Escaped text never contains a raw tab, so the field count tells the
-- four-field (timestamped) format apart from the old three-field one.
local function read_ops(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local ops, epoch = {}, nil
  for line in f:lines() do
    local ts, o, d, t = line:match("^(%d+)\t(%d+)\t(%d+)\t(.*)$")
    if not ts then
      o, d, t = line:match("^(%d+)\t(%d+)\t(.*)$")
    end
    if o then
      ops[#ops + 1] = { tonumber(o), tonumber(d), unesc(t), ts and tonumber(ts) }
    elseif not epoch then
      local e = line:match("^#replayvim\tepoch\t(%d+)")
      if e then epoch = tonumber(e) end
    end
  end
  f:close()
  return ops, epoch
end

local function fold(ops)
  local s = ""
  for _, op in ipairs(ops) do
    local off = math.min(op[1], #s)
    local del = math.min(op[2], #s - off)
    s = s:sub(1, off) .. op[3] .. s:sub(off + del + 1)
  end
  return s
end

-- Report ops that don't fit the document at the point they're applied.
-- A healthy log returns an empty list.
local function validate(ops)
  local bad, s = {}, ""
  for i, op in ipairs(ops) do
    local off, del = op[1], op[2]
    if off > #s then
      bad[#bad + 1] = string.format("op %d: offset %d past end of %d-byte doc", i, off, #s)
    elseif off + del > #s then
      bad[#bad + 1] = string.format("op %d: deletes to %d, doc is %d bytes", i, off + del, #s)
    end
    off = math.min(off, #s)
    del = math.min(del, #s - off)
    s = s:sub(1, off) .. op[3] .. s:sub(off + del + 1)
  end
  return bad, s
end

--------------------------------------------------------------------------
-- permissions
--
-- Plain arithmetic rather than bit ops so this works on both LuaJIT and
-- PUC Lua builds of nvim. 512 = 0o1000, so `mode % 512` keeps rwxrwxrwx
-- and drops the file type and setuid/setgid/sticky bits.
--------------------------------------------------------------------------

local OWNER_W = 128 -- 0o200

local function file_perms(path)
  local st = path and uv.fs_stat(path)
  return st and (st.mode % 512) or nil
end

-- What the log's permissions should be, or nil if the source isn't on disk.
local function wanted_perms(bufnr)
  local p = file_perms(src_path(bufnr))
  if not p then return nil end
  if math.floor(p / OWNER_W) % 2 == 0 then p = p + OWNER_W end
  return p
end

local function sync_perms(sess, bufnr)
  if IS_WIN then return end
  if not api.nvim_buf_is_valid(bufnr) then return end
  local want = wanted_perms(bufnr)
  if not want then return end
  local have = file_perms(sess.path)
  if not have or have == want then return end

  local ok, err = uv.fs_chmod(sess.path, want)
  if ok then
    sess.perm_warned = false
  elseif not sess.perm_warned then
    sess.perm_warned = true
    vim.notify(string.format(
      "ReplayVim: %s is %03o but should be %03o to match the source, and chmod failed: %s",
      sess.path, have, want, tostring(err)), vim.log.levels.WARN)
  end
end

--------------------------------------------------------------------------
-- recording
--------------------------------------------------------------------------

-- bufnr -> { path, base_len, pending, lo, hi_base, hi_state,
--            epoch, perm_warned, dirty }
-- epoch is nil until the log has been written with a header.
-- pending holds { unix_time_or_false, "<off>\t<del>\t<text>" }; false marks
-- the seed op. The relative timestamp is filled in at flush time, once the
-- epoch is known.
-- lo/hi_base/hi_state describe the uncommitted dirty span:
--   lo        first byte touched (same coord in both base and buffer)
--   hi_base   end of the affected region, in pre-change (log) coordinates
--   hi_state  end of the affected region, in current buffer coordinates
local sessions = {}

local function flush(sess, bufnr)
  if #sess.pending == 0 then return end
  if not sess.dirty then return end -- nothing worth persisting yet: opening
                                     -- and reading a file is not an edit
  -- First write to this log fixes the epoch: the time of the first real op,
  -- so that op is exactly 0 and nothing after it can be negative.
  local epoch = sess.epoch
  if not epoch then
    for _, p in ipairs(sess.pending) do
      if p[1] then epoch = p[1] break end
    end
    epoch = epoch or os.time()
  end
  local lines = {}
  if not sess.epoch then lines[1] = header_line(epoch) end
  for _, p in ipairs(sess.pending) do
    -- The seed op is the starting point, so it sits at 0.
    lines[#lines + 1] = string.format("%d\t%s", p[1] and (p[1] - epoch) or 0, p[2])
  end
  local chunk = table.concat(lines, "\n") .. "\n"

  -- Create with the source's permissions up front (umask still applies),
  -- so there's no window where a new log is more open than its source.
  local created = not log_exists(sess.path)
  local mode = (bufnr and wanted_perms(bufnr)) or 384 -- 0o600 fallback
  local fd, oerr = uv.fs_open(sess.path, "a", mode)
  if not fd then
    vim.notify("ReplayVim: cannot write " .. sess.path .. ": " .. tostring(oerr),
      vim.log.levels.WARN)
    sess.pending = {}
    return
  end
  local wrote, werr = uv.fs_write(fd, chunk, -1)
  uv.fs_close(fd)
  sess.pending = {}
  if not wrote then
    vim.notify("ReplayVim: write failed for " .. sess.path .. ": " .. tostring(werr),
      vim.log.levels.WARN)
    return
  end
  sess.epoch = epoch
  if created and bufnr then sync_perms(sess, bufnr) end
end

-- seed = true for the starting-point op recorded at open: it must not
-- trigger the first write on its own.
local function emit(sess, off, del, ins, seed)
  sess.pending[#sess.pending + 1] =
    { not seed and os.time(), string.format("%d\t%d\t%s", off, del, esc(ins)) }
  sess.base_len = sess.base_len - del + #ins
  if seed then return end
  sess.dirty = true
  -- No log yet: write now, so the epoch is the first edit, not whenever
  -- the buffer happens to fill up.
  if not sess.epoch or #sess.pending >= config.flush_every then
    flush(sess, sess.bufnr)
  end
end

-- Last resort: replace the whole document. Only runs if the integrity check
-- fails or a region read errors, so the log heals rather than rots.
local function full_resync(sess, bufnr)
  local now = buf_text(bufnr)
  sess.lo, sess.hi_base, sess.hi_state = nil, nil, nil
  if #now == sess.base_len then return end
  emit(sess, 0, sess.base_len, now)
end

-- Widen the dirty span. Pure integer arithmetic, no API calls, no allocation.
-- Called once per on_bytes event, i.e. per keystroke.
local function touch(sess, off, del, inslen)
  if not sess.lo then
    sess.lo, sess.hi_base, sess.hi_state = off, off + del, off + inslen
    return
  end
  local shift = sess.hi_state - sess.hi_base
  local end_state = off + del
  if end_state > sess.hi_state then
    sess.hi_state = end_state
    sess.hi_base  = end_state - shift
  end
  sess.hi_state = sess.hi_state + (inslen - del)
  if off < sess.lo then sess.lo = off end
  if sess.hi_state < sess.lo then sess.hi_state = sess.lo end
  if sess.hi_base  < sess.lo then sess.hi_base  = sess.lo end
end

-- Turn the accumulated dirty span into exactly one log op.
local function commit(sess, bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end
  if not sess.lo then return end

  local dlen = doc_len(bufnr)
  local lo       = math.max(0, math.min(sess.lo, math.min(sess.base_len, dlen)))
  local hi_state = math.max(lo, math.min(sess.hi_state, dlen))
  local del      = math.max(0, math.min(sess.hi_base, sess.base_len) - lo)

  local ins = read_region(bufnr, lo, hi_state)
  sess.lo, sess.hi_base, sess.hi_state = nil, nil, nil

  if ins == nil then
    full_resync(sess, bufnr)
    return
  end
  if del > 0 or ins ~= "" then emit(sess, lo, del, ins) end

  -- O(1) integrity check: our idea of the length vs the buffer's.
  if sess.base_len ~= dlen then full_resync(sess, bufnr) end
end

local function detach(bufnr)
  local sess = sessions[bufnr]
  if sess then
    commit(sess, bufnr)
    flush(sess, bufnr)
    sessions[bufnr] = nil
  end
  pcall(api.nvim_del_augroup_by_name, "ReplayVim_" .. bufnr)
end

function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if sessions[bufnr] then return end
  if not api.nvim_buf_is_valid(bufnr) then return end
  if vim.b[bufnr].replayvim_scratch then return end
  if vim.bo[bufnr].buftype ~= "" then return end

  local path = log_path(bufnr)
  if not path then return end

  -- One full read at open: fold the log and reconcile against the file.
  -- After this we never materialise the document again.
  local existed = log_exists(path)
  local ops, epoch = read_ops(path)
  local logged = ops and fold(ops) or ""
  local sess = {
    path = path,
    bufnr = bufnr,
    base_len = #logged,
    pending = {},
    dirty = false,
    -- nil for a new log, or an old one with no header: set on first write.
    epoch = epoch,
    perm_warned = false,
  }
  sessions[bufnr] = sess

  local now = buf_text(bufnr)
  if now ~= logged then
    -- If there was no log yet, this is just recording the file's starting
    -- point, not a change -- don't let it create a .replay file on its own.
    emit(sess, 0, #logged, now, not existed)
  end

  -- Open-time permission check.
  if existed then sync_perms(sess, bufnr) end

  api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, b, _, _, _, start_byte, _, _, old_end_byte, _, _, new_end_byte)
      local s = sessions[b]
      if not s then return true end -- detach
      touch(s, start_byte, old_end_byte, new_end_byte)
    end,
    on_reload = function(_, b)
      vim.schedule(function()
        local s = sessions[b]
        if s and api.nvim_buf_is_valid(b) then full_resync(s, b) end
      end)
    end,
    on_detach = function(_, b) detach(b) end,
  })

  local grp = api.nvim_create_augroup("ReplayVim_" .. bufnr, { clear = true })

  -- Commit points: a completed normal-mode change, or a completed insert
  -- session. Deliberately NOT TextChangedI -- that's the keystroke firehose.
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = grp,
    buffer = bufnr,
    callback = function()
      local s = sessions[bufnr]
      if s then commit(s, bufnr) end
    end,
  })

  api.nvim_create_autocmd({ "BufWritePost", "BufFilePost" }, {
    group = grp,
    buffer = bufnr,
    callback = function()
      local s = sessions[bufnr]
      if s then
        commit(s, bufnr)
        flush(s, bufnr)
        -- Source may be new on disk, or its mode may have changed.
        sync_perms(s, bufnr)
      end
    end,
  })

  api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    group = grp,
    buffer = bufnr,
    callback = function() detach(bufnr) end,
  })
end

-- User-facing wrapper around attach(): notifies so an explicit
-- :ReplayVimStartTracking has visible feedback (M.attach itself stays
-- silent, since auto_attach calls it on every buffer open).
function M.start_tracking(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if sessions[bufnr] then
    vim.notify("ReplayVim: already tracking this buffer", vim.log.levels.WARN)
    return
  end
  M.attach(bufnr)
  if sessions[bufnr] then
    vim.notify("ReplayVim: tracking " .. sessions[bufnr].path)
  else
    vim.notify(
      "ReplayVim: couldn't start tracking (no file name, or an unsupported buffer type)",
      vim.log.levels.WARN)
  end
end

function M.stop_tracking(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local sess = sessions[bufnr]
  if not sess then
    vim.notify("ReplayVim: not tracking this buffer", vim.log.levels.WARN)
    return
  end
  local path = sess.path
  detach(bufnr)
  vim.notify("ReplayVim: stopped tracking " .. path)
end

--------------------------------------------------------------------------
-- replay
--------------------------------------------------------------------------

local replay = { timer = nil }

function M.stop()
  if replay.timer then
    replay.timer:stop()
    if not replay.timer:is_closing() then replay.timer:close() end
    replay.timer = nil
  end
end

local function set_winbar(win, text)
  pcall(function() vim.wo[win].winbar = text end)
end

function M.replay(gap_ms)
  local gap = math.max(1, tonumber(gap_ms) or config.gap_ms)

  local src = api.nvim_get_current_buf()
  if vim.b[src].replayvim_scratch then
    vim.notify("ReplayVim: that's already a replay buffer", vim.log.levels.WARN)
    return
  end

  local path = log_path(src)
  if not path then
    vim.notify("ReplayVim: buffer has no file name", vim.log.levels.WARN)
    return
  end

  if sessions[src] then
    commit(sessions[src], src)
    flush(sessions[src], src)
  end

  local ops = read_ops(path)
  if not ops or #ops == 0 then
    vim.notify("ReplayVim: no history at " .. path, vim.log.levels.WARN)
    return
  end

  local bad = validate(ops)
  if #bad > 0 then
    vim.notify(string.format(
      "ReplayVim: %d malformed op(s) in log, clamping. :ReplayVimCheck for detail", #bad),
      vim.log.levels.WARN)
  end

  M.stop()

  local ft = vim.bo[src].filetype
  local title = vim.fn.fnamemodify(api.nvim_buf_get_name(src), ":t")

  local buf = api.nvim_create_buf(false, true)
  vim.b[buf].replayvim_scratch = true
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1 -- don't build undo history for the replay
  pcall(function() vim.bo[buf].filetype = ft end)
  pcall(api.nvim_buf_set_name, buf, "replayvim://" .. title)

  vim.cmd("vsplit")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  set_winbar(win, string.format(" ReplayVim  %s  0/%d ", title, #ops))

  local state, i = "", 0
  local timer = uv.new_timer()
  replay.timer = timer

  timer:start(gap, gap, vim.schedule_wrap(function()
    if not api.nvim_buf_is_valid(buf) or not api.nvim_win_is_valid(win) then
      M.stop()
      return
    end

    i = i + 1
    local op = ops[i]
    if not op then
      M.stop()
      set_winbar(win, string.format(" ReplayVim  %s  done (%d ops) ", title, #ops))
      return
    end

    -- Clamp rather than trust: a malformed op degrades to a visible jump
    -- instead of aborting the whole replay.
    local off = math.min(op[1], #state)
    local del = math.min(op[2], #state - off)
    local ins = op[3]

    local sr, sc = offset_to_rc(state, off)
    local er, ec = offset_to_rc(state, off + del)
    local ok = pcall(api.nvim_buf_set_text, buf, sr, sc, er, ec,
      vim.split(ins, "\n", { plain = true }))

    state = state:sub(1, off) .. ins .. state:sub(off + del + 1)

    if not ok then
      -- Self-heal: rewrite the buffer wholesale and keep going.
      pcall(api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(state, "\n", { plain = true }))
    end

    local cr, cc = offset_to_rc(state, off + #ins)
    pcall(api.nvim_win_set_cursor, win, { cr + 1, cc })
    set_winbar(win, string.format(" ReplayVim  %s  %d/%d ", title, i, #ops))
  end))
end

--------------------------------------------------------------------------
-- VHS tape export
--
-- Turns the op log into a .tape script (github.com/charmbracelet/vhs) that
-- drives a real nvim and renders the edit history as a GIF.
--
-- Each op is a hidden cursor-positioning + deletion via a :lua one-liner,
-- followed by the inserted text typed out visibly, so the GIF looks like
-- someone writing the file.
--------------------------------------------------------------------------

local tape_defaults = {
  output = nil,            -- defaults to <file>.gif
  width = 1200,
  height = 600,
  font_size = 22,
  theme = nil,             -- e.g. "Catppuccin Frappe"
  typing_speed = "40ms",
  gap = nil,               -- pause after each op; defaults to config.gap_ms
  final_sleep = "3s",
  nvim_cmd = "nvim -u NONE",
  fast_over = 200,         -- inserts longer than this are typed at fast_speed
  fast_speed = "3ms",      -- ...so the seed op doesn't take three minutes
}

local function tsplit(s, sep)
  local t, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then t[#t + 1] = s:sub(i) break end
    t[#t + 1] = s:sub(i, j - 1)
    i = j + #sep
  end
  return t
end

-- VHS `Type` has no escape sequences: you quote the string with a character
-- it doesn't contain. Three are available (" ' `), so split the text into
-- chunks that each leave at least one quote character free.
local function type_chunks(text)
  local chunks, cur, seen, nseen = {}, {}, {}, 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    local isq = (ch == '"' or ch == "'" or ch == "`")
    if isq and not seen[ch] and nseen == 2 then
      chunks[#chunks + 1] = table.concat(cur)
      cur, seen, nseen = {}, {}, 0
    end
    cur[#cur + 1] = ch
    if isq and not seen[ch] then
      seen[ch] = true
      nseen = nseen + 1
    end
  end
  if #cur > 0 then chunks[#chunks + 1] = table.concat(cur) end
  return chunks
end

local function quote_for(s)
  if not s:find('"', 1, true) then return '"' end
  if not s:find("'", 1, true) then return "'" end
  if not s:find("`", 1, true) then return "`" end
  return nil
end

-- Literal text -> Type / Enter / Tab commands. Newlines and tabs become key
-- presses; they can't survive inside a quoted Type argument.
local function emit_text(out, text, speed)
  local suffix = speed and ("@" .. speed) or ""
  local lines = tsplit(text, "\n")
  for li, line in ipairs(lines) do
    if li > 1 then out[#out + 1] = "Enter" end
    local parts = tsplit(line, "\t")
    for pi, part in ipairs(parts) do
      if pi > 1 then out[#out + 1] = "Tab" end
      for _, chunk in ipairs(type_chunks(part)) do
        if chunk ~= "" then
          out[#out + 1] = "Type" .. suffix .. " " .. quote_for(chunk) .. chunk .. quote_for(chunk)
        end
      end
    end
  end
end

function M.tape(outfile, opts)
  local bufnr = api.nvim_get_current_buf()
  if vim.b[bufnr].replayvim_scratch then
    vim.notify("ReplayVim: that's a replay buffer", vim.log.levels.WARN)
    return
  end

  local path = log_path(bufnr)
  if not path then
    vim.notify("ReplayVim: buffer has no file name", vim.log.levels.WARN)
    return
  end

  local s = sessions[bufnr]
  if s then
    commit(s, bufnr)
    flush(s, bufnr)
  end

  local ops = read_ops(path)
  if not ops or #ops == 0 then
    vim.notify("ReplayVim: no history at " .. path, vim.log.levels.WARN)
    return
  end

  local t = {}
  for k, v in pairs(tape_defaults) do t[k] = v end
  for k, v in pairs(config.tape or {}) do t[k] = v end
  for k, v in pairs(opts or {}) do t[k] = v end

  local src = api.nvim_buf_get_name(bufnr)
  local base = vim.fn.fnamemodify(src, ":t")
  local ft = vim.bo[bufnr].filetype
  outfile = outfile or (vim.fn.fnamemodify(src, ":r") .. ".tape")
  local gif = t.output or (vim.fn.fnamemodify(src, ":r") .. ".gif")
  local gap = t.gap or (config.gap_ms .. "ms")

  local out = {}
  local function w(line) out[#out + 1] = line end

  w("# Generated by ReplayVim from " .. path)
  w("# Render with:  vhs " .. vim.fn.fnamemodify(outfile, ":t"))
  w("")
  -- Settings must all appear before the first non-setting command.
  w("Output " .. gif)
  w("Require nvim")
  w("")
  w('Set Shell "bash"')
  w(("Set Width %d"):format(t.width))
  w(("Set Height %d"):format(t.height))
  w(("Set FontSize %d"):format(t.font_size))
  if t.theme then w(('Set Theme "%s"'):format(t.theme)) end
  w("Set TypingSpeed " .. t.typing_speed)
  w("")

  -- Setup, hidden. -u NONE keeps the render independent of local config;
  -- virtualedit=onemore lets the cursor sit past the last character so an
  -- append at end-of-line lands in the right place; paste stops autoindent
  -- and completion from mangling what we type.
  w("Hide")
  w('Type "cd $(mktemp -d) && clear"')
  w("Enter")
  w("Sleep 500ms")
  w(('Type "%s %s"'):format(t.nvim_cmd, base))
  w("Enter")
  w("Sleep 2s")
  w('Type ":set virtualedit=onemore paste noswapfile"')
  w("Enter")
  w('Type ":syntax on"')
  w("Enter")
  if ft ~= "" and ft:match("^[%w_%-%.]+$") then
    w(('Type ":set filetype=%s"'):format(ft))
    w("Enter")
  end
  w("Show")

  local state = ""
  for _, op in ipairs(ops) do
    local off = math.max(0, math.min(op[1], #state))
    local del = math.max(0, math.min(op[2], #state - off))
    local ins = op[3]

    local sr, sc = offset_to_rc(state, off)
    local er, ec = offset_to_rc(state, off + del)

    w("")
    w("Hide")
    w("Escape")
    -- Delete the replaced range and park the cursor at the insert point.
    w(('Type ":lua vim.api.nvim_buf_set_text(0,%d,%d,%d,%d,{%s}) '
      .. 'vim.api.nvim_win_set_cursor(0,{%d,%d})"')
      :format(sr, sc, er, ec, "''", sr + 1, sc))
    w("Enter")
    w('Type "i"')
    w("Show")

    if ins ~= "" then
      emit_text(out, ins, #ins > t.fast_over and t.fast_speed or nil)
    end
    w("Sleep " .. gap)

    state = state:sub(1, off) .. ins .. state:sub(off + del + 1)
  end

  w("")
  w("Escape")
  w("Sleep " .. t.final_sleep)
  w("Hide")
  w('Type ":q!"')
  w("Enter")

  local f = io.open(outfile, "w")
  if not f then
    vim.notify("ReplayVim: cannot write " .. outfile, vim.log.levels.ERROR)
    return
  end
  f:write(table.concat(out, "\n"), "\n")
  f:close()

  vim.notify(("ReplayVim: wrote %s (%d ops)"):format(outfile, #ops))
  return outfile
end

--------------------------------------------------------------------------
-- diagnostics
--------------------------------------------------------------------------

function M.check(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local path = log_path(bufnr)
  if not path then return end
  local ops, epoch = read_ops(path)
  if not ops then
    vim.notify("ReplayVim: no log at " .. path, vim.log.levels.WARN)
    return
  end

  local bad, final = validate(ops)
  local lines = { path, string.format("%d ops, folds to %d bytes", #ops, #final) }

  if epoch then
    local last, untimed = nil, 0
    for _, op in ipairs(ops) do
      if op[4] then last = op[4] else untimed = untimed + 1 end
    end
    lines[#lines + 1] = string.format("epoch %d (%s), last op at +%ds%s",
      epoch, os.date("%Y-%m-%d %H:%M:%S", epoch), last or 0,
      untimed > 0 and string.format(", %d untimed legacy op(s)", untimed) or "")
  else
    lines[#lines + 1] = "no epoch header (legacy log, ops are untimed)"
  end

  if not IS_WIN then
    local have, want = file_perms(path), wanted_perms(bufnr)
    if have and want then
      lines[#lines + 1] = (have == want)
          and string.format("permissions %03o match source", have)
          or string.format("permissions %03o, source wants %03o", have, want)
    end
  end

  if #bad == 0 then
    lines[#lines + 1] = "log is well formed"
  else
    lines[#lines + 1] = string.format("%d malformed op(s):", #bad)
    for j = 1, math.min(#bad, 10) do lines[#lines + 1] = "  " .. bad[j] end
    if #bad > 10 then lines[#lines + 1] = string.format("  ... and %d more", #bad - 10) end
  end

  local live = buf_text(bufnr)
  lines[#lines + 1] = (final == live)
      and "log matches current buffer"
      or string.format("log does NOT match buffer (log %d bytes, buffer %d)", #final, #live)

  vim.notify(table.concat(lines, "\n"), #bad > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

function M.clear(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local path = log_path(bufnr)
  if not path then return end
  local had = sessions[bufnr] ~= nil
  sessions[bufnr] = nil
  pcall(api.nvim_del_augroup_by_name, "ReplayVim_" .. bufnr)
  os.remove(path)
  if had then M.attach(bufnr) end -- restart clean, reseeded from current text
  vim.notify("ReplayVim: cleared " .. path)
end

--------------------------------------------------------------------------
-- wiring
--------------------------------------------------------------------------

api.nvim_create_user_command("ReplayVimStartTracking", function() M.start_tracking() end,
  { desc = "Start recording this buffer's edits" })

api.nvim_create_user_command("ReplayVimStopTracking", function() M.stop_tracking() end,
  { desc = "Stop recording this buffer's edits" })

api.nvim_create_user_command("ReplayVim", function(o)
  M.replay(o.args ~= "" and o.args or nil)
end, { nargs = "?", desc = "Replay this file's edit history" })

api.nvim_create_user_command("ReplayVimStop", function() M.stop() end,
  { desc = "Stop the running replay" })

api.nvim_create_user_command("ReplayVimTape", function(o)
  M.tape(o.args ~= "" and vim.fn.expand(o.args) or nil)
end, { nargs = "?", complete = "file", desc = "Export this file's history as a VHS .tape" })

api.nvim_create_user_command("ReplayVimCheck", function() M.check() end,
  { desc = "Validate this file's replay log" })

api.nvim_create_user_command("ReplayVimClear", function() M.clear() end,
  { desc = "Delete this file's replay log" })

local grp = api.nvim_create_augroup("ReplayVim", { clear = true })

if config.auto_attach then
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = grp,
    callback = function(ev) M.attach(ev.buf) end,
  })
end

api.nvim_create_autocmd("VimLeavePre", {
  group = grp,
  callback = function()
    for b, s in pairs(sessions) do
      commit(s, b)
      flush(s, b)
    end
  end,
})

_G.ReplayVim = M
return M
