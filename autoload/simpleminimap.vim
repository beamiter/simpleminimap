vim9script

const PROTOCOL_VERSION = 2
const MIN_RENDER_HEIGHT = 1
const MAX_BACKEND_RESTARTS = 3
# Search projection scans the whole source buffer; skip absurdly large ones.
const SEARCH_MAX_LINES = 100000
# Multiple signs can land on one minimap row; the highest priority wins.
const SIGN_PRIORITY = {
  error: 6,
  warning: 5,
  info: 4,
  delete: 3,
  change: 2,
  add: 1,
  other: 0,
}
const SIGN_GROUPS = {
  error: 'SimpleMinimapSignError',
  warning: 'SimpleMinimapSignWarning',
  info: 'SimpleMinimapSignInfo',
  delete: 'SimpleMinimapSignDelete',
  change: 'SimpleMinimapSignChange',
  add: 'SimpleMinimapSignAdd',
  other: 'SimpleMinimapSign',
}
# Density shade classes reported per rendered cell by the daemon.
const SHADE_TYPES = {
  '1': 'SimpleMinimapShadeLow',
  '2': 'SimpleMinimapShadeMid',
  '3': 'SimpleMinimapShadeHigh',
}
var plugin_root = fnamemodify(expand('<sfile>:p'), ':h:h')

# key (minimap window ID as string) -> session dictionary.
var sessions: dict<any> = {}
var requests: dict<string> = {}
var incoming: dict<any> = {}
var backend_job: any = v:null
var backend_path = ''
var backend_ready = false
var backend_error = ''
var backend_restart_timer = 0
var backend_restart_attempts = 0
var backend_stopping = false
var backend_restart_requested = false
var next_request_id = 0
var internal_change = false
var ping_id = 0
var ping_started: any = []
var backend_latency_ms = -1.0


# Kept as a ring buffer, not just an echo: the interesting backend events
# happen during startup and crashes, long before a user thinks to switch
# g:simpleminimap_debug on.
var log_ring: list<string> = []

def Log(message: string)
  log_ring->add(strftime('%H:%M:%S') .. ' ' .. message)
  if len(log_ring) > 500
    log_ring = log_ring[-300 : ]
  endif
  if get(g:, 'simpleminimap_debug', 0)
    echom '[SimpleMinimap] ' .. message
  endif
enddef

export def ShowLog(): void
  new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setline(1, empty(log_ring) ? ['(no log entries)'] : log_ring)
  setlocal nomodifiable
  normal! G
enddef


def WindowInfo(winid: number): dict<any>
  if winid <= 0
    return {}
  endif
  var found = getwininfo(winid)
  return empty(found) ? {} : found[0]
enddef


def WindowExists(winid: number): bool
  var tabwin = win_id2tabwin(winid)
  return len(tabwin) >= 2 && tabwin[0] > 0 && tabwin[1] > 0
enddef


def IsMinimapBuffer(bufnr: number): bool
  return bufnr > 0 && getbufvar(bufnr, '&filetype') ==# 'simpleminimap'
enddef


def IsEligibleSourceWindow(winid: number): bool
  var info = WindowInfo(winid)
  if empty(info) || IsMinimapBuffer(info.bufnr)
    return false
  endif
  var buftype = getbufvar(info.bufnr, '&buftype')
  if type(buftype) != v:t_string || buftype !=# ''
    return false
  endif
  var ignored = get(g:, 'simpleminimap_ignore_filetypes', [])
  var filetype = getbufvar(info.bufnr, '&filetype')
  return type(ignored) != v:t_list || index(ignored, filetype) < 0
enddef


def FindSourceWindow(tabnr: number, preferred: number = 0): number
  if preferred > 0 && IsEligibleSourceWindow(preferred)
    var preferred_info = WindowInfo(preferred)
    if get(preferred_info, 'tabnr', 0) == tabnr
      return preferred
    endif
  endif

  for info in getwininfo()
    if get(info, 'tabnr', 0) == tabnr && IsEligibleSourceWindow(info.winid)
      return info.winid
    endif
  endfor
  return 0
enddef


def ForgetRequestsForSession(key: string)
  for request_key in keys(requests)
    if requests[request_key] ==# key
      requests->remove(request_key)
      if has_key(incoming, request_key)
        incoming->remove(request_key)
      endif
    endif
  endfor
enddef


def DropSession(key: string): dict<any>
  if !has_key(sessions, key)
    return {}
  endif
  var session = sessions[key]
  if get(session, 'timer', 0) > 0
    timer_stop(session.timer)
  endif
  ClearMatches(key)
  sessions->remove(key)
  ForgetRequestsForSession(key)
  return session
enddef


def PruneSessions()
  for key in keys(sessions)
    var session = sessions[key]
    if !WindowExists(get(session, 'winid', 0)) || !bufexists(get(session, 'bufnr', -1))
      DropSession(key)
    endif
  endfor
enddef


def SessionKeyForTab(tabnr: number): string
  PruneSessions()
  for [key, session] in items(sessions)
    var info = WindowInfo(get(session, 'winid', 0))
    if !empty(info) && get(info, 'tabnr', 0) == tabnr
      return key
    endif
  endfor
  return ''
enddef


def CurrentSessionKey(): string
  return SessionKeyForTab(tabpagenr())
enddef


def Clamp(value: number, minimum: number, maximum: number): number
  return min([maximum, max([minimum, value])])
enddef


def DaemonCandidates(): list<string>
  var suffix = has('win32') || has('win64') ? '.exe' : ''
  var name = 'simpleminimap-daemon' .. suffix
  var result: list<string> = []
  var configured = expand(get(g:, 'simpleminimap_daemon_path', ''))
  if configured !=# ''
    result->add(configured)
  endif

  result->add(plugin_root .. '/lib/' .. name)
  result->add(plugin_root .. '/target/release/' .. name)
  result->add(plugin_root .. '/target/debug/' .. name)

  for entry in split(&runtimepath, ',')
    if entry ==# ''
      continue
    endif
    result->add(fnamemodify(entry, ':p') .. '/lib/' .. name)
  endfor

  var in_path = exepath(name)
  if in_path !=# ''
    result->add(in_path)
  endif
  return result
enddef


def FindDaemon(): string
  for candidate in DaemonCandidates()
    var path = simplify(fnamemodify(candidate, ':p'))
    if filereadable(path) && executable(path)
      return path
    endif
  endfor
  return ''
enddef


def BackendRunning(): bool
  if type(backend_job) != v:t_job
    return false
  endif
  try
    return job_status(backend_job) ==# 'run'
  catch
    return false
  endtry
enddef


def RejectResponse(request_key: string, message: string)
  backend_error = message
  var key = ''
  if has_key(requests, request_key)
    key = requests->remove(request_key)
  endif
  if has_key(incoming, request_key)
    incoming->remove(request_key)
  endif
  if key !=# '' && has_key(sessions, key)
    var session = sessions[key]
    if string(get(session, 'request_id', 0)) ==# request_key
      RenderMessage(key, ['SimpleMinimap backend error', message])
    endif
  endif
  Log('rejected backend response ' .. request_key .. ': ' .. message)
enddef


def BackendOut(_channel: channel, message: string)
  if message ==# ''
    return
  endif
  var fields = split(message, "\t", 1)
  if empty(fields)
    return
  endif

  if fields[0] ==# 'READY'
    backend_ready = len(fields) == 2 && str2nr(fields[1]) == PROTOCOL_VERSION
    if !backend_ready
      backend_error = 'backend protocol version mismatch'
      for key in keys(sessions)
        RenderMessage(key, ['SimpleMinimap backend error', backend_error])
      endfor
    else
      backend_error = ''
      for key in keys(sessions)
        Schedule(key, 0)
      endfor
      SendPing()
    endif
    Log('backend ready: ' .. message)
    return
  endif

  if fields[0] ==# 'PONG'
    if len(fields) >= 2 && str2nr(fields[1]) == ping_id
        && type(ping_started) == v:t_list && !empty(ping_started)
      backend_latency_ms = reltimefloat(reltime(ping_started)) * 1000.0
      ping_started = []
    endif
    return
  endif

  if fields[0] ==# 'X'
    var id = len(fields) > 1 ? str2nr(fields[1]) : 0
    var error = len(fields) > 2 ? DecodeField(fields[2]) : 'unknown backend error'
    Log(printf('backend error for request %d: %s', id, error))
    RejectResponse(string(id), error)
    return
  endif

  if len(fields) < 2 || fields[1] !~# '^\d\+$'
    return
  endif
  var request_id = str2nr(fields[1])
  var request_key = string(request_id)
  if !has_key(requests, request_key)
    return
  endif

  if fields[0] ==# 'B'
    if has_key(incoming, request_key)
      RejectResponse(request_key, 'duplicate response header')
      return
    endif
    if len(fields) != 4 || fields[2] !~# '^\d\+$' || fields[3] !~# '^\d\+$'
      RejectResponse(request_key, 'malformed response header')
      return
    endif
    var source_lines = str2nr(fields[2])
    var expected = str2nr(fields[3])
    var session_key = requests[request_key]
    var dimensions = has_key(sessions, session_key) ? WindowDimensions(sessions[session_key].winid) : [0, 0]
    if source_lines <= 0 || expected <= 0 || expected > 2000
        || dimensions[1] <= 0 || expected > dimensions[1]
      RejectResponse(request_key, 'invalid response dimensions')
      return
    endif
    incoming[request_key] = {
      source_lines: source_lines,
      expected: expected,
      rows: [],
    }
  elseif fields[0] ==# 'R'
    if len(fields) != 6 || !has_key(incoming, request_key)
      RejectResponse(request_key, 'row without a valid response header')
      return
    endif
    if fields[2] !~# '^\d\+$' || fields[3] !~# '^\d\+$'
      RejectResponse(request_key, 'malformed response row range')
      return
    endif
    var response = incoming[request_key]
    var start_line = str2nr(fields[2])
    var end_line = str2nr(fields[3])
    var expected_start = empty(response.rows) ? 1 : response.rows[-1].end + 1
    var text = DecodeField(fields[4])
    var shade = fields[5]
    if start_line != expected_start || end_line < start_line || end_line > response.source_lines
      RejectResponse(request_key, 'non-contiguous response row range')
      return
    endif
    if len(response.rows) >= response.expected || strchars(text) > 256
      RejectResponse(request_key, 'response row exceeds declared limits')
      return
    endif
    if shade !~# '^[0-3]\+$' || strlen(shade) != strchars(text)
      RejectResponse(request_key, 'malformed response shade data')
      return
    endif
    response.rows->add({start: start_line, end: end_line, text: text, shade: shade})
  elseif fields[0] ==# 'E'
    if len(fields) != 2 || !has_key(incoming, request_key)
      RejectResponse(request_key, 'render end without a valid response')
      return
    endif
    var response = incoming->remove(request_key)
    if len(response.rows) != response.expected
        || empty(response.rows)
        || response.rows[-1].end != response.source_lines
      RejectResponse(request_key, 'incomplete backend response')
      return
    endif
    var session_key = requests->remove(request_key)
    if !has_key(sessions, session_key)
      return
    endif
    var session = sessions[session_key]
    if get(session, 'request_id', 0) != request_id
      return
    endif
    ApplyRows(session_key, response.rows, response.source_lines)
  else
    RejectResponse(request_key, 'unknown backend response command')
  endif
enddef


def SendPing()
  if !BackendRunning() || !backend_ready
    return
  endif
  next_request_id += 1
  if next_request_id <= 0
    next_request_id = 1
  endif
  ping_id = next_request_id
  ping_started = reltime()
  try
    ch_sendraw(backend_job, printf("P\t%d\n", ping_id))
  catch
    ping_started = []
  endtry
enddef


def BackendErr(_channel: channel, message: string)
  if message ==# ''
    return
  endif
  backend_error = message
  Log('backend stderr: ' .. message)
enddef


def BackendRestartTimer(_timer: number)
  backend_restart_timer = 0
  if BackendRunning()
    backend_restart_timer = timer_start(50, BackendRestartTimer)
    return
  endif
  for key in keys(sessions)
    Schedule(key, 0)
  endfor
enddef


def ScheduleBackendRestart(delay: number)
  if backend_restart_timer > 0
    timer_stop(backend_restart_timer)
  endif
  backend_restart_timer = timer_start(max([0, delay]), BackendRestartTimer)
enddef


def BackendExit(exited_job: job, status: number)
  if type(backend_job) == v:t_job
      && get(job_info(exited_job), 'process', -1) != get(job_info(backend_job), 'process', -2)
    Log('ignored exit callback from a superseded backend job')
    return
  endif
  var explicitly_requested = backend_restart_requested
  var unexpected = !backend_stopping
  backend_job = v:null
  backend_ready = false
  backend_error = printf('backend exited with status %d', status)
  backend_latency_ms = -1.0
  ping_started = []
  requests = {}
  incoming = {}
  backend_stopping = false
  backend_restart_requested = false
  Log(backend_error)
  var should_restart = explicitly_requested
  if unexpected && get(g:, 'simpleminimap_auto_restart', 1)
      && backend_restart_attempts < MAX_BACKEND_RESTARTS
    backend_restart_attempts += 1
    should_restart = true
  endif
  if should_restart && !empty(sessions)
    var delays = [100, 350, 1000]
    var delay_index = Clamp(backend_restart_attempts - 1, 0, len(delays) - 1)
    for key in keys(sessions)
      RenderMessage(key, ['SimpleMinimap', 'restarting backend…'])
    endfor
    ScheduleBackendRestart(explicitly_requested ? 0 : delays[delay_index])
  else
    for key in keys(sessions)
      RenderMessage(key, ['SimpleMinimap backend stopped', backend_error])
    endfor
  endif
enddef


def StartBackend(): bool
  if BackendRunning()
    return true
  endif
  if backend_stopping
    backend_error = 'backend is restarting'
    return false
  endif

  backend_path = FindDaemon()
  if backend_path ==# ''
    backend_ready = false
    backend_error = 'daemon not found; run install.sh (or install.ps1)'
    return false
  endif

  try
    backend_ready = false
    backend_error = ''
    backend_job = job_start([backend_path], {
      in_io: 'pipe',
      out_io: 'pipe',
      err_io: 'pipe',
      in_mode: 'raw',
      out_mode: 'nl',
      err_mode: 'nl',
      out_cb: BackendOut,
      err_cb: BackendErr,
      exit_cb: BackendExit,
      stoponexit: 'term',
      noblock: 1,
    })
  catch
    backend_error = 'failed to start backend: ' .. v:exception
    backend_ready = false
    backend_job = v:null
    return false
  endtry

  if !BackendRunning()
    backend_error = 'failed to start backend: ' .. backend_path
    backend_ready = false
    return false
  endif
  Log('started backend: ' .. backend_path)
  return true
enddef


def StopBackend(restart: bool = false)
  if backend_restart_timer > 0
    timer_stop(backend_restart_timer)
    backend_restart_timer = 0
  endif
  backend_restart_requested = restart
  backend_stopping = true
  backend_ready = false
  requests = {}
  incoming = {}
  if BackendRunning()
    try
      job_stop(backend_job)
    catch
      backend_job = v:null
      backend_stopping = false
    endtry
  else
    backend_job = v:null
    backend_stopping = false
    backend_restart_requested = false
    if restart && !empty(sessions)
      ScheduleBackendRestart(0)
    endif
  endif
enddef


def EncodeField(value: string): string
  var encoded = substitute(value, '%', '%25', 'g')
  encoded = substitute(encoded, "\t", '%09', 'g')
  encoded = substitute(encoded, "\r", '%0D', 'g')
  encoded = substitute(encoded, "\n", '%0A', 'g')
  return encoded
enddef


def DecodeField(value: string): string
  var output = value
  output = substitute(output, '%0[Aa]', "\n", 'g')
  output = substitute(output, '%0[Dd]', "\r", 'g')
  output = substitute(output, '%09', "\t", 'g')
  output = substitute(output, '%25', '%', 'g')
  return output
enddef


def FitLine(value: string, width: number): string
  var result = strcharpart(value, 0, width)
  var display_width = strdisplaywidth(result)
  while display_width > width && strchars(result) > 0
    result = strcharpart(result, 0, strchars(result) - 1)
    display_width = strdisplaywidth(result)
  endwhile
  if display_width < width
    result ..= repeat(' ', width - display_width)
  endif
  return result
enddef


def SetBufferLines(bufnr: number, lines: list<string>)
  if !bufexists(bufnr)
    return
  endif
  var safe_lines = empty(lines) ? [''] : lines
  setbufvar(bufnr, '&modifiable', 1)
  setbufline(bufnr, 1, safe_lines)
  var info = getbufinfo(bufnr)
  if !empty(info) && info[0].linecount > len(safe_lines)
    deletebufline(bufnr, len(safe_lines) + 1, '$')
  endif
  setbufvar(bufnr, '&modified', 0)
  setbufvar(bufnr, '&modifiable', 0)
enddef


def WindowDimensions(winid: number): list<number>
  var info = WindowInfo(winid)
  if empty(info)
    return [0, 0]
  endif
  return [get(info, 'width', 0), get(info, 'height', 0)]
enddef


def RenderMessage(key: string, message_lines: list<string>)
  if !has_key(sessions, key)
    return
  endif
  ForgetRequestsForSession(key)
  var session = sessions[key]
  var dimensions = WindowDimensions(session.winid)
  if dimensions[0] <= 0 || dimensions[1] <= 0
    return
  endif
  var output: list<string> = []
  for line in message_lines
    output->add(FitLine(line, dimensions[0]))
  endfor
  while len(output) < dimensions[1]
    output->add(repeat(' ', dimensions[0]))
  endwhile
  session.rows = []
  session.source_lines = 0
  session.last_signature = ''
  SetBufferLines(session.bufnr, output)
  ClearShading(key)
  ClearMatches(key)
enddef


def NormalizeDisplayCells(text: string, max_columns: number, tabstop: number): string
  if text !~# '[^\x09\x20-\x7E]'
    return text
  endif
  var output = ''
  var logical_column = 0
  var char_index = 0
  var char_count = strchars(text)
  while char_index < char_count && logical_column < max_columns
    var ch = strcharpart(text, char_index, 1)
    if ch ==# "\t"
      output ..= ch
      logical_column = min([max_columns, ((logical_column / tabstop) + 1) * tabstop])
    else
      var cell_width = strdisplaywidth(ch)
      if cell_width > 0
        cell_width = min([cell_width, max_columns - logical_column])
        output ..= repeat(ch, cell_width)
        logical_column += cell_width
      endif
    endif
    char_index += 1
  endwhile
  return strcharpart(output, 0, max_columns)
enddef


def SampleText(bufnr: number, line_number: number, max_chars: number, tabstop: number): string
  var text = getbufline(bufnr, line_number)
  if empty(text)
    return ''
  endif
  return NormalizeDisplayCells(strcharpart(text[0], 0, max_chars), max_chars, tabstop)
enddef


def InkScore(text: string): number
  return strchars(substitute(text, '\s', '', 'g'))
enddef


def RepresentativeSample(bufnr: number, start_line: number, end_line: number, max_chars: number, tabstop: number): string
  var midpoint = start_line + ((end_line - start_line) / 2)
  if get(g:, 'simpleminimap_sampling', 'adaptive') !=# 'adaptive' || start_line == end_line
    return SampleText(bufnr, midpoint, max_chars, tabstop)
  endif

  var candidates = [start_line, midpoint, end_line]
  var best_text = ''
  var best_score = -1
  var best_distance = end_line - start_line + 1
  var visited: dict<bool> = {}
  for line_number in candidates
    var candidate_key = string(line_number)
    if has_key(visited, candidate_key)
      continue
    endif
    visited[candidate_key] = true
    var text = SampleText(bufnr, line_number, max_chars, tabstop)
    var score = InkScore(text)
    var distance = abs(line_number - midpoint)
    if score > best_score || (score == best_score && distance < best_distance)
      best_text = text
      best_score = score
      best_distance = distance
    endif
  endfor
  return best_text
enddef


def BuildSampleGroup(bufnr: number, start_line: number, end_line: number, max_chars: number, tabstop: number): list<string>
  var samples: list<string> = []
  var count = end_line - start_line + 1
  if count <= 4
    var line_number = start_line
    while line_number <= end_line
      samples->add(SampleText(bufnr, line_number, max_chars, tabstop))
      line_number += 1
    endwhile
    while len(samples) < 4
      samples->add('')
    endwhile
    return samples
  endif

  for sample_index in range(0, 3)
    var bucket_start = start_line + ((sample_index * count) / 4)
    var bucket_end = start_line + ((((sample_index + 1) * count) / 4) - 1)
    bucket_end = min([end_line, max([bucket_start, bucket_end])])
    samples->add(RepresentativeSample(bufnr, bucket_start, bucket_end, max_chars, tabstop))
  endfor
  return samples
enddef


def BuildRequestBody(key: string): dict<any>
  var session = sessions[key]
  var dimensions = WindowDimensions(session.winid)
  var width = Clamp(dimensions[0], 1, 256)
  var height = Clamp(dimensions[1], MIN_RENDER_HEIGHT, 2000)
  var source_info = getbufinfo(session.source_bufnr)
  if empty(source_info)
    return {}
  endif
  var source_lines = max([1, get(source_info[0], 'linecount', 1)])
  var row_count = min([height, max([1, (source_lines + 3) / 4])])
  var max_columns = Clamp(get(g:, 'simpleminimap_max_columns', 120), 20, 1000)
  var tabstop = Clamp(getbufvar(session.source_bufnr, '&tabstop'), 1, 64)
  var style = get(g:, 'simpleminimap_render_style', 'braille')
  if index(['braille', 'blocks', 'ascii'], style) < 0
    style = 'braille'
  endif

  var groups: list<string> = []
  for row_index in range(0, row_count - 1)
    var start_zero = (row_index * source_lines) / row_count
    var end_zero = (((row_index + 1) * source_lines) / row_count) - 1
    var start_line = start_zero + 1
    var end_line = max([start_line, end_zero + 1])
    var samples = BuildSampleGroup(session.source_bufnr, start_line, end_line, max_columns, tabstop)
    groups->add(printf("%d\t%d\t%s\t%s\t%s\t%s",
      start_line, end_line,
      EncodeField(samples[0]), EncodeField(samples[1]), EncodeField(samples[2]), EncodeField(samples[3])))
  endfor
  return {
    width: width,
    height: height,
    max_columns: max_columns,
    tabstop: tabstop,
    style: style,
    source_lines: source_lines,
    groups: groups,
  }
enddef


def BodySignature(body: dict<any>): string
  var raw = printf("%d|%d|%d|%d|%s|%d\n", body.width, body.height,
    body.max_columns, body.tabstop, body.style, body.source_lines)
    .. join(body.groups, "\n")
  return exists('*sha256') ? sha256(raw) : raw
enddef


def FormatPayload(body: dict<any>, request_id: number): string
  var parts: list<string> = []
  parts->add(printf("B\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d",
    request_id, body.width, body.height, body.max_columns, body.tabstop,
    body.style, body.source_lines, len(body.groups), PROTOCOL_VERSION))
  for group in body.groups
    parts->add(printf("G\t%d\t%s", request_id, group))
  endfor
  parts->add(printf("E\t%d", request_id))
  return join(parts, "\n") .. "\n"
enddef


def RenderSession(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  session.timer = 0
  if !WindowExists(session.winid) || !IsEligibleSourceWindow(session.source_winid)
    RenderMessage(key, ['SimpleMinimap', 'no editable window'])
    return
  endif
  if !StartBackend()
    RenderMessage(key, ['SimpleMinimap', backend_error])
    return
  endif
  if !backend_ready
    RenderMessage(key, ['SimpleMinimap', backend_error ==# '' ? 'starting backend…' : backend_error])
    return
  endif

  session.source_bufnr = WindowInfo(session.source_winid).bufnr
  var body = BuildRequestBody(key)
  if empty(body)
    RenderMessage(key, ['SimpleMinimap', 'source buffer unavailable'])
    return
  endif

  var signature = BodySignature(body)
  var force = get(session, 'force_render', false)
  session.force_render = false
  if !force && !empty(session.rows) && signature ==# get(session, 'last_signature', '')
    # The daemon would produce identical output; refresh the overlays only.
    session.render_skips = get(session, 'render_skips', 0) + 1
    UpdateSigns(key)
    UpdateViewport(key)
    UpdateSearch(key)
    return
  endif

  ForgetRequestsForSession(key)
  next_request_id += 1
  if next_request_id <= 0
    next_request_id = 1
  endif
  var request_id = next_request_id
  session.request_id = request_id
  session.request_started = reltime()
  session.request_signature = signature
  var payload = FormatPayload(body, request_id)

  requests[string(request_id)] = key
  try
    ch_sendraw(backend_job, payload)
  catch
    if has_key(requests, string(request_id))
      requests->remove(string(request_id))
    endif
    backend_error = 'failed to send render request: ' .. v:exception
    RenderMessage(key, ['SimpleMinimap', backend_error])
  endtry
enddef


def RenderTimer(key: string, _timer: number)
  RenderSession(key)
enddef


def Schedule(key: string, delay: number = -1, force: bool = false)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if force
    session.force_render = true
  endif
  if get(session, 'timer', 0) > 0
    timer_stop(session.timer)
    session.timer = 0
  endif
  var wait = delay >= 0 ? delay : get(g:, 'simpleminimap_debounce', 80)
  if wait <= 0
    RenderSession(key)
  else
    session.timer = timer_start(wait, function(RenderTimer, [key]))
  endif
enddef


def DeleteMatch(key: string, field: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var match_id = get(session, field, -1)
  if match_id > 0 && WindowExists(session.winid)
    try
      matchdelete(match_id, session.winid)
    catch
    endtry
  endif
  session[field] = -1
enddef


def ShadingEnabled(): bool
  return get(g:, 'simpleminimap_shading', 1) != 0 && has('textprop') == 1
enddef


def EnsureShadeProps()
  for type_name in values(SHADE_TYPES)
    if empty(prop_type_get(type_name))
      prop_type_add(type_name, {highlight: type_name})
    endif
  endfor
enddef


def ClearShading(key: string)
  if !has_key(sessions, key) || has('textprop') != 1
    return
  endif
  var session = sessions[key]
  if !bufexists(session.bufnr)
    return
  endif
  for type_name in values(SHADE_TYPES)
    if !empty(prop_type_get(type_name))
      try
        prop_remove({type: type_name, bufnr: session.bufnr, all: true}, 1, max([1, get(getbufinfo(session.bufnr)[0], 'linecount', 1)]))
      catch
      endtry
    endif
  endfor
enddef


def ApplyShading(key: string, output: list<string>)
  if !has_key(sessions, key) || !ShadingEnabled()
    return
  endif
  var session = sessions[key]
  if !bufexists(session.bufnr)
    return
  endif
  EnsureShadeProps()
  ClearShading(key)
  var lnum = 0
  for row in session.rows
    lnum += 1
    if lnum > len(output)
      break
    endif
    var text = output[lnum - 1]
    var shade = get(row, 'shade', '')
    var limit = min([strlen(shade), strchars(text)])
    var cell = 0
    while cell < limit
      var class = shade[cell]
      if class ==# '0'
        cell += 1
        continue
      endif
      var run_start = cell
      while cell < limit && shade[cell] ==# class
        cell += 1
      endwhile
      var byte_start = byteidx(text, run_start)
      var byte_end = byteidx(text, cell)
      if byte_start >= 0 && byte_end > byte_start
        try
          prop_add(lnum, byte_start + 1, {
            length: byte_end - byte_start,
            type: SHADE_TYPES[class],
            bufnr: session.bufnr,
          })
        catch
        endtry
      endif
    endwhile
  endfor
enddef


def ClearSignMatches(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  for match_id in get(session, 'sign_matches', [])
    if match_id > 0 && WindowExists(session.winid)
      try
        matchdelete(match_id, session.winid)
      catch
      endtry
    endif
  endfor
  session.sign_matches = []
  session.sign_rows = []
  session.sign_categories = {}
enddef


def ClearMatches(key: string)
  if !has_key(sessions, key)
    return
  endif
  for field in ['viewport_match', 'cursor_match', 'search_match']
    DeleteMatch(key, field)
  endfor
  ClearSignMatches(key)
  sessions[key].search_rows = []
  sessions[key].search_state = []
enddef


def SignCategory(name: string): string
  var lowered = tolower(name)
  if lowered =~# 'error'
    return 'error'
  elseif lowered =~# 'warn'
    return 'warning'
  elseif lowered =~# 'info\|hint\|note'
    return 'info'
  elseif lowered =~# 'delete\|remove'
    return 'delete'
  elseif lowered =~# 'add\|new\|untracked'
    return 'add'
  elseif lowered =~# 'change\|modif'
    return 'change'
  endif
  return 'other'
enddef


def UpdateSigns(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  ClearSignMatches(key)
  if !get(g:, 'simpleminimap_show_signs', 1)
      || !WindowExists(session.winid)
      || empty(session.rows)
      || !bufexists(session.source_bufnr)
    return
  endif

  var placed: list<any> = []
  try
    placed = sign_getplaced(session.source_bufnr, {group: '*'})
  catch
    Log('could not read source signs: ' .. v:exception)
    return
  endtry
  if empty(placed) || empty(get(placed[0], 'signs', []))
    return
  endif

  var row_category: dict<string> = {}
  for sign in placed[0].signs
    var minimap_row = RowForSourceLine(session.rows, get(sign, 'lnum', 0))
    if minimap_row <= 0
      continue
    endif
    var category = SignCategory(get(sign, 'name', ''))
    var row_key = string(minimap_row)
    var existing = get(row_category, row_key, '')
    if existing ==# '' || SIGN_PRIORITY[category] > SIGN_PRIORITY[existing]
      row_category[row_key] = category
    endif
  endfor
  if empty(row_category)
    return
  endif

  var category_rows: dict<any> = {}
  var all_rows: list<number> = []
  for [row_key, category] in items(row_category)
    if !has_key(category_rows, category)
      category_rows[category] = []
    endif
    category_rows[category]->add(str2nr(row_key))
    all_rows->add(str2nr(row_key))
  endfor
  session.sign_rows = sort(all_rows, 'n')
  session.sign_categories = row_category
  for [category, rows] in items(category_rows)
    session.sign_matches->add(matchaddpos(SIGN_GROUPS[category], sort(rows, 'n'), 15, -1, {window: session.winid}))
  endfor
enddef


def UpdateSearch(key: string, force: bool = false)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var supported = exists('*matchbufline')
  var enabled = supported && get(g:, 'simpleminimap_show_search', 1)
  var state: list<any> = enabled
    ? [v:hlsearch, @/, getbufvar(session.source_bufnr, 'changedtick', 0)]
    : []
  # [-1] is a sentinel no real state (empty, or [hlsearch, pattern, tick]) equals.
  if !force && state ==# get(session, 'search_state', [-1])
    return
  endif
  session.search_state = state
  DeleteMatch(key, 'search_match')
  session.search_rows = []
  if !enabled || !v:hlsearch || @/ ==# ''
      || empty(session.rows)
      || !WindowExists(session.winid)
      || !bufexists(session.source_bufnr)
      || session.source_lines > SEARCH_MAX_LINES
    return
  endif

  var matches: list<any> = []
  try
    matches = matchbufline(session.source_bufnr, @/, 1, '$')
  catch
    return
  endtry
  var positions: list<number> = []
  var seen: dict<bool> = {}
  for found in matches
    var minimap_row = RowForSourceLine(session.rows, get(found, 'lnum', 0))
    var row_key = string(minimap_row)
    if minimap_row > 0 && !has_key(seen, row_key)
      seen[row_key] = true
      positions->add(minimap_row)
    endif
  endfor
  session.search_rows = sort(positions, 'n')
  if !empty(positions)
    session.search_match = matchaddpos('SimpleMinimapSearch', positions, 12, -1, {window: session.winid})
  endif
enddef


def RowForSourceLine(rows: list<any>, source_line: number): number
  var index = 0
  while index < len(rows)
    if source_line >= rows[index].start && source_line <= rows[index].end
      return index + 1
    endif
    index += 1
  endwhile
  if empty(rows)
    return 0
  endif
  return source_line < rows[0].start ? 1 : len(rows)
enddef


def UpdateViewport(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if !WindowExists(session.winid) || !WindowExists(session.source_winid) || empty(session.rows)
    ClearMatches(key)
    return
  endif

  var source_info = WindowInfo(session.source_winid)
  if empty(source_info)
    ClearMatches(key)
    return
  endif
  var top_line = max([1, get(source_info, 'topline', 1)])
  var bottom_line = max([top_line, get(source_info, 'botline', top_line)])
  var cursor_pos = getcurpos(session.source_winid)
  var cursor_line = len(cursor_pos) > 1 ? cursor_pos[1] : top_line
  var first_row = RowForSourceLine(session.rows, top_line)
  var last_row = RowForSourceLine(session.rows, bottom_line)
  var cursor_row = RowForSourceLine(session.rows, cursor_line)

  DeleteMatch(key, 'viewport_match')
  DeleteMatch(key, 'cursor_match')
  if first_row > 0 && last_row >= first_row
    var positions: list<any> = []
    for line_number in range(first_row, last_row)
      positions->add(line_number)
    endfor
    session.viewport_match = matchaddpos('SimpleMinimapViewport', positions, 10, -1, {window: session.winid})
  endif
  if cursor_row > 0
    session.cursor_match = matchaddpos('SimpleMinimapCursor', [cursor_row], 20, -1, {window: session.winid})
  endif
enddef


def ApplyRows(key: string, rows: list<any>, source_lines: number)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var dimensions = WindowDimensions(session.winid)
  if dimensions[0] <= 0 || dimensions[1] <= 0
    return
  endif

  var output: list<string> = []
  for row in rows
    output->add(FitLine(row.text, dimensions[0]))
  endfor
  while len(output) < dimensions[1]
    output->add(repeat(' ', dimensions[0]))
  endwhile
  if len(output) > dimensions[1]
    output = output[0 : dimensions[1] - 1]
  endif

  session.rows = rows
  session.source_lines = source_lines
  session.last_signature = get(session, 'request_signature', '')
  session.render_count = get(session, 'render_count', 0) + 1
  var started = get(session, 'request_started', [])
  if type(started) == v:t_list && !empty(started)
    session.last_render_ms = reltimefloat(reltime(started)) * 1000.0
  endif
  backend_restart_attempts = 0
  backend_error = ''
  SetBufferLines(session.bufnr, output)
  ApplyShading(key, output)
  UpdateSigns(key)
  UpdateViewport(key)
  UpdateSearch(key, true)
  redrawstatus
enddef


# The canonical minimap 'statusline'.  Exported so a statusline manager can ask
# for the value instead of hard-coding the literal and drifting from it.
export def StatuslineExpr(): string
  return get(g:, 'simpleminimap_show_statusline', 1)
    ? '%#SimpleMinimapTitle#%{simpleminimap#Statusline()}%*'
    : ''
enddef


# The window-local state the minimap defends for the whole life of the window.
# Setting it once at creation is not enough: a statusline manager's WinEnter
# handler, a `:windo setlocal`, a session restore or a colour-scheme reload all
# rewrite window-local options behind our back, and the minimap then shows an
# empty title (or loses winfixwidth and gets squeezed) until it is reopened.
# Idempotent and compare-before-assign, because ReassertWindow() runs it on
# every WinEnter into a minimap window.
def ApplyWindowOptions(winid: number)
  var statusline = StatuslineExpr()
  if getwinvar(winid, '&statusline', '') !=# statusline
    setwinvar(winid, '&statusline', statusline)
  endif
  if getwinvar(winid, '&wincolor', '') !=# 'SimpleMinimapNormal'
    setwinvar(winid, '&wincolor', 'SimpleMinimapNormal')
  endif
  # getwinvar() hands back a Bool for a boolean option under Vim9, so compare
  # with ! rather than against 1.
  if !getwinvar(winid, '&winfixwidth', false)
    setwinvar(winid, '&winfixwidth', 1)
  endif
enddef


# Re-apply the defended options when a minimap window is entered.  Runs on
# every BufWinEnter/WinEnter in the editor, so it must stay cheap: for a
# non-minimap window this is one dict lookup and nothing else.
export def ReassertWindow(winid: number)
  if winid <= 0 || !has_key(sessions, string(winid))
    return
  endif
  ApplyWindowOptions(winid)
enddef


def ConfigureMinimapWindow(winid: number, bufnr: number)
  win_execute(winid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodeline undolevels=-1')
  win_execute(winid, 'setlocal nowrap nonumber norelativenumber nocursorcolumn nocursorline')
  win_execute(winid, 'setlocal signcolumn=no foldcolumn=0 nofoldenable nolist')
  win_execute(winid, 'setlocal scrolloff=0 sidescrolloff=0')
  win_execute(winid, 'setlocal filetype=simpleminimap')
  ApplyWindowOptions(winid)
  setbufvar(bufnr, '&modifiable', 0)
  setbufvar(bufnr, '&modified', 0)

  win_execute(winid, 'nnoremap <silent> <buffer> q <Cmd>SimpleMinimapClose<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <Esc> <Cmd>call simpleminimap#FocusSource()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> r <Cmd>SimpleMinimapRefresh<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> s <Cmd>SimpleMinimapStyle<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> p <Cmd>SimpleMinimapTogglePin<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> + <Cmd>call simpleminimap#AdjustWidth(2)<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> - <Cmd>call simpleminimap#AdjustWidth(-2)<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <Space> <Cmd>call simpleminimap#Preview()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <CR> <Cmd>call simpleminimap#Jump()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <LeftMouse> <LeftMouse><Cmd>call simpleminimap#MouseDown()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <LeftDrag> <Cmd>call simpleminimap#MouseDrag()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <LeftRelease> <Cmd>call simpleminimap#MouseUp()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <ScrollWheelUp> <Cmd>call simpleminimap#ScrollSource(-1)<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <ScrollWheelDown> <Cmd>call simpleminimap#ScrollSource(1)<CR>')
enddef


def OpenForCurrentTab()
  var tabnr = tabpagenr()
  if SessionKeyForTab(tabnr) !=# ''
    return
  endif
  var source_winid = FindSourceWindow(tabnr, win_getid())
  if source_winid <= 0
    echohl WarningMsg
    echom '[SimpleMinimap] no normal file window is available in this tab.'
    echohl None
    return
  endif

  var minimap_winid = 0
  var opened_key = ''
  internal_change = true
  try
    if get(g:, 'simpleminimap_side', 'right') ==# 'left'
      topleft vertical new
    else
      botright vertical new
    endif
    minimap_winid = win_getid()
    execute 'vertical resize ' .. get(g:, 'simpleminimap_width', 18)
    var minimap_bufnr = bufnr()
    var key = string(minimap_winid)
    opened_key = key
    sessions[key] = {
      winid: minimap_winid,
      bufnr: minimap_bufnr,
      source_winid: source_winid,
      source_bufnr: WindowInfo(source_winid).bufnr,
      pinned: false,
      rows: [],
      source_lines: 0,
      request_id: 0,
      timer: 0,
      viewport_match: -1,
      cursor_match: -1,
      search_match: -1,
      sign_matches: [],
      sign_rows: [],
      sign_categories: {},
      search_rows: [],
      search_state: [],
      preview_origin: [],
      request_started: [],
      request_signature: '',
      last_signature: '',
      force_render: false,
      render_count: 0,
      render_skips: 0,
      last_render_ms: -1.0,
    }
    ConfigureMinimapWindow(minimap_winid, minimap_bufnr)
    SetBufferLines(minimap_bufnr, ['SimpleMinimap starting…'])
    win_gotoid(source_winid)
    Schedule(key, 0)
  catch
    if opened_key !=# '' && has_key(sessions, opened_key)
      DropSession(opened_key)
    endif
    if WindowExists(minimap_winid) && winnr('$') > 1
      win_execute(minimap_winid, 'close!')
    endif
    echohl WarningMsg
    echom '[SimpleMinimap] could not open minimap: ' .. v:exception
    echohl None
  finally
    internal_change = false
  endtry
enddef


def RestoreNormalWindow(winid: number)
  win_execute(winid, 'enew!')
  win_execute(winid, 'setlocal wrap< number< relativenumber< cursorcolumn< cursorline<')
  win_execute(winid, 'setlocal signcolumn< foldcolumn< foldenable< list<')
  win_execute(winid, 'setlocal scrolloff< sidescrolloff< winfixwidth< wincolor< statusline<')
enddef


def CloseSession(key: string)
  var session = DropSession(key)
  if empty(session) || !WindowExists(session.winid)
    return
  endif

  var info = WindowInfo(session.winid)
  var is_last_window = !empty(info) && tabpagewinnr(info.tabnr, '$') <= 1
  internal_change = true
  try
    if is_last_window
      # Vim cannot close the final window.  Replace the scratch buffer and
      # restore the window-local options instead of leaving a narrow minimap.
      RestoreNormalWindow(session.winid)
    else
      win_execute(session.winid, 'close!')
    endif
  finally
    internal_change = false
  endtry
enddef


export def SetupHighlights()
  highlight default link SimpleMinimapNormal Comment
  highlight default link SimpleMinimapViewport Visual
  highlight default link SimpleMinimapCursor Search
  highlight default link SimpleMinimapSearch IncSearch
  highlight default link SimpleMinimapSign WarningMsg
  highlight default link SimpleMinimapSignError ErrorMsg
  highlight default link SimpleMinimapSignWarning WarningMsg
  highlight default link SimpleMinimapSignInfo MoreMsg
  highlight default link SimpleMinimapSignAdd DiffAdd
  highlight default link SimpleMinimapSignChange DiffChange
  highlight default link SimpleMinimapSignDelete DiffDelete
  highlight default link SimpleMinimapShadeLow NonText
  highlight default link SimpleMinimapShadeMid Comment
  highlight default link SimpleMinimapShadeHigh Normal
  highlight default link SimpleMinimapTitle Title
enddef


# A colour-scheme reload re-defines every group and can leave a window pointing
# at a group that no longer exists, so re-link ours *and* re-assert the
# window-local state that depends on them.
export def OnColorScheme()
  SetupHighlights()
  for session in values(sessions)
    if WindowExists(get(session, 'winid', 0))
      ApplyWindowOptions(session.winid)
    endif
  endfor
enddef


export def Toggle()
  var key = CurrentSessionKey()
  if key ==# ''
    OpenForCurrentTab()
  else
    CloseSession(key)
  endif
enddef


export def Open()
  OpenForCurrentTab()
enddef


export def Close()
  var key = CurrentSessionKey()
  if key !=# ''
    CloseSession(key)
  endif
enddef


export def Refresh(all: bool = false)
  PruneSessions()
  if all
    # Snapshot the backing buffer as well as the window-id key. Autocommands
    # may close a session while a forced render is being scheduled; never let
    # a replacement that reuses that id inherit the old refresh operation.
    var snapshot: list<dict<any>> = []
    for key in keys(sessions)
      snapshot->add({key: key, bufnr: sessions[key].bufnr})
    endfor
    for item in snapshot
      if has_key(sessions, item.key)
            \ && get(sessions[item.key], 'bufnr', 0) == item.bufnr
            \ && WindowExists(get(sessions[item.key], 'winid', 0))
        Schedule(item.key, 0, true)
      endif
    endfor
    return
  endif
  var key = CurrentSessionKey()
  if key !=# ''
    Schedule(key, 0, true)
  endif
enddef


export def Focus()
  var key = CurrentSessionKey()
  if key ==# ''
    OpenForCurrentTab()
    key = CurrentSessionKey()
  endif
  if key !=# '' && has_key(sessions, key)
    win_gotoid(sessions[key].winid)
  endif
enddef


export def FocusSource()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var source_winid = sessions[key].source_winid
  if WindowExists(source_winid)
    win_gotoid(source_winid)
  endif
enddef


def SetPinned(value: bool)
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    if value
      OpenForCurrentTab()
      key = CurrentSessionKey()
    endif
    if key ==# '' || !has_key(sessions, key)
      return
    endif
  endif

  var session = sessions[key]
  session.pinned = value
  if !value
    # Unpinning from another ordinary split should immediately follow that
    # split; otherwise the next WinEnter would be required to make it visible.
    var current_winid = win_getid()
    if current_winid != session.winid && IsEligibleSourceWindow(current_winid)
      var info = WindowInfo(current_winid)
      var changed = session.source_winid != current_winid || session.source_bufnr != info.bufnr
      session.source_winid = current_winid
      session.source_bufnr = info.bufnr
      session.preview_origin = []
      if changed
        Schedule(key, 0)
      endif
    endif
  endif
  redrawstatus
  echom printf('[SimpleMinimap] source %s', value ? 'pinned' : 'following active window')
enddef


export def Pin()
  SetPinned(true)
enddef


export def Unpin()
  SetPinned(false)
enddef


export def TogglePin()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    SetPinned(true)
    return
  endif
  SetPinned(!get(sessions[key], 'pinned', false))
enddef


export def MaybeAutoOpen()
  if !get(g:, 'simpleminimap_auto_open', 0) || CurrentSessionKey() !=# ''
    return
  endif
  if IsEligibleSourceWindow(win_getid())
    OpenForCurrentTab()
  endif
enddef


export def CompleteStyle(lead: string, _command: string, _cursor: number): list<string>
  var matches: list<string> = []
  for style in ['braille', 'blocks', 'ascii']
    if stridx(style, lead) == 0
      matches->add(style)
    endif
  endfor
  return matches
enddef


export def SetStyle(value: string)
  var styles = ['braille', 'blocks', 'ascii']
  var style = value
  if style ==# ''
    var current = index(styles, get(g:, 'simpleminimap_render_style', 'braille'))
    style = styles[current < 0 ? 0 : (current + 1) % len(styles)]
  endif
  if index(styles, style) < 0
    echohl WarningMsg
    echom '[SimpleMinimap] style must be braille, blocks or ascii.'
    echohl None
    return
  endif
  g:simpleminimap_render_style = style
  for key in keys(sessions)
    Schedule(key, 0)
  endfor
  redrawstatus
enddef


export def Resize(value: string)
  if value ==# ''
    echom printf('[SimpleMinimap] width: %d', get(g:, 'simpleminimap_width', 18))
    return
  endif
  if value !~# '^\d\+$'
    echohl WarningMsg
    echom '[SimpleMinimap] width must be a number in 6..80.'
    echohl None
    return
  endif
  var width = Clamp(str2nr(value), 6, 80)
  g:simpleminimap_width = width
  # Width is a global option, so its runtime command must not leave minimaps
  # in background tabs at an old value. Apply it to every live session just as
  # SetStyle() already applies a global style change to every session.
  PruneSessions()
  for key in keys(sessions)
    if has_key(sessions, key) && WindowExists(sessions[key].winid)
      win_execute(sessions[key].winid, 'vertical resize ' .. width)
      Schedule(key, 0)
    endif
  endfor
enddef


export def AdjustWidth(delta: number)
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var dimensions = WindowDimensions(sessions[key].winid)
  if dimensions[0] > 0
    Resize(string(dimensions[0] + delta))
  endif
enddef


export def Restart()
  backend_restart_attempts = 0
  for key in keys(sessions)
    RenderMessage(key, ['SimpleMinimap', 'restarting backend…'])
  endfor
  StopBackend(true)
enddef


export def Statusline(): string
  var winid = get(g:, 'statusline_winid', win_getid())
  var key = string(winid)
  if !has_key(sessions, key)
    return ' SimpleMinimap '
  endif
  var session = sessions[key]
  var source_name = bufname(get(session, 'source_bufnr', -1))
  var label = source_name ==# '' ? '[No Name]' : fnamemodify(source_name, ':t')
  var style = get(g:, 'simpleminimap_render_style', 'braille')
  var state = backend_ready ? '' : ' !'
  var last_render_ms = get(session, 'last_render_ms', -1.0)
  var timing = last_render_ms >= 0.0 ? printf(' · %.0fms', last_render_ms) : ''
  var pinned = get(session, 'pinned', false) ? ' · pinned' : ''
  var position = ''
  var source_lines = get(session, 'source_lines', 0)
  if source_lines > 0 && WindowExists(get(session, 'source_winid', 0))
    var cursor_pos = getcurpos(session.source_winid)
    if len(cursor_pos) > 1
      position = printf(' · %d%%', min([100, (cursor_pos[1] * 100 + source_lines - 1) / source_lines]))
    endif
  endif
  return printf(' %s · %s%s%s%s%s ', label, style, pinned, position, timing, state)
enddef


def SourceTargetForRow(session: dict<any>, row_number: number): number
  if row_number < 1 || row_number > len(session.rows)
    return 0
  endif
  var row = session.rows[row_number - 1]
  return row.start + ((row.end - row.start) / 2)
enddef


def MoveSourceToRow(key: string, row_number: number, focus_source: bool): bool
  if !has_key(sessions, key)
    return false
  endif
  var session = sessions[key]
  var target = SourceTargetForRow(session, row_number)
  if target <= 0 || !WindowExists(session.source_winid)
    return false
  endif

  if focus_source
    internal_change = true
    try
      if !win_gotoid(session.source_winid)
        return false
      endif
      var origin = get(session, 'preview_origin', [])
      if type(origin) == v:t_list && len(origin) >= 3
        cursor(origin[1], origin[2])
      endif
      execute 'normal! ' .. target .. 'G'
      normal! zv
      normal! zz
    finally
      session.preview_origin = []
      internal_change = false
    endtry
  else
    if empty(get(session, 'preview_origin', []))
      session.preview_origin = getcurpos(session.source_winid)
    endif
    internal_change = true
    try
      win_execute(session.source_winid, printf('call cursor(%d, 1)', target))
      win_execute(session.source_winid, 'normal! zv')
      win_execute(session.source_winid, 'normal! zz')
    finally
      internal_change = false
    endtry
  endif
  UpdateViewport(key)
  return true
enddef


export def Jump()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if empty(session.rows)
    return
  endif
  MoveSourceToRow(key, line('.'), true)
enddef


export def Preview()
  var key = CurrentSessionKey()
  if key !=# ''
    MoveSourceToRow(key, line('.'), false)
  endif
enddef


def NavigateMouse(focus_source: bool): bool
  var mouse = getmousepos()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return false
  endif
  var session = sessions[key]
  if get(mouse, 'winid', 0) != session.winid
    return false
  endif
  var raw_row = get(mouse, 'line', 0)
  if raw_row < 1 || empty(session.rows)
    return false
  endif
  var row_number = Clamp(raw_row, 1, len(session.rows))
  win_gotoid(session.winid)
  cursor(row_number, 1)
  return MoveSourceToRow(key, row_number, focus_source)
enddef


export def MouseDown()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  NavigateMouse(false)
enddef


export def MouseDrag()
  var key = CurrentSessionKey()
  if key !=# '' && has_key(sessions, key)
    NavigateMouse(false)
  endif
enddef


export def MouseUp()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  if !NavigateMouse(true)
    win_gotoid(sessions[key].source_winid)
  endif
enddef


export def MouseJump()
  # Backward-compatible public entry point used by older mappings.
  NavigateMouse(true)
enddef


export def ScrollSource(direction: number)
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key) || direction == 0
    return
  endif
  var session = sessions[key]
  var info = WindowInfo(session.source_winid)
  var source_info = getbufinfo(session.source_bufnr)
  if empty(info) || empty(source_info)
    return
  endif
  var step = get(g:, 'simpleminimap_mouse_scroll_lines', 3)
  var source_lines = max([1, get(source_info[0], 'linecount', 1)])
  var target_top = Clamp(get(info, 'topline', 1) + (direction * step), 1, source_lines)
  internal_change = true
  try
    win_execute(session.source_winid, 'call winrestview({"topline": ' .. target_top .. '})')
  finally
    internal_change = false
  endtry
  UpdateViewport(key)
enddef


export def OnContextChanged()
  if internal_change
    return
  endif
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var current_winid = win_getid()
  if current_winid == session.winid
    return
  endif
  if get(session, 'pinned', false)
    # Pinning is window-scoped: changing buffers inside the pinned split keeps
    # following it, while entering another split cannot steal the minimap.
    if IsEligibleSourceWindow(session.source_winid)
      if current_winid == session.source_winid
        var pinned_info = WindowInfo(current_winid)
        var pinned_changed = session.source_bufnr != pinned_info.bufnr
        session.source_bufnr = pinned_info.bufnr
        session.preview_origin = []
        if pinned_changed || empty(session.rows)
          Schedule(key, 0)
        else
          UpdateViewport(key)
        endif
        redrawstatus
      endif
      return
    endif
    # A closed or ineligible pinned split cannot remain a useful source.  Fall
    # back to the normal replacement policy instead of stranding the minimap.
    session.pinned = false
    redrawstatus
  endif
  if !IsEligibleSourceWindow(current_winid)
    if current_winid == session.source_winid || !IsEligibleSourceWindow(session.source_winid)
      var tab_info = WindowInfo(session.winid)
      var replacement = empty(tab_info) ? 0 : FindSourceWindow(tab_info.tabnr)
      if replacement > 0
        session.source_winid = replacement
        session.source_bufnr = WindowInfo(replacement).bufnr
        session.preview_origin = []
        Schedule(key, 0)
      elseif get(g:, 'simpleminimap_auto_close', 0)
        CloseSession(key)
      else
        RenderMessage(key, ['SimpleMinimap', 'no editable window'])
      endif
    endif
    return
  endif
  var info = WindowInfo(current_winid)
  var changed = session.source_winid != current_winid || session.source_bufnr != info.bufnr
  if current_winid == session.source_winid
    session.preview_origin = []
  endif
  session.source_winid = current_winid
  session.source_bufnr = info.bufnr
  if changed || empty(session.rows)
    session.preview_origin = []
    Schedule(key, 0)
  else
    UpdateViewport(key)
  endif
  redrawstatus
enddef


export def OnTextChanged(bufnr: number)
  if internal_change || IsMinimapBuffer(bufnr)
    return
  endif
  for [key, session] in items(sessions)
    if get(session, 'source_bufnr', -1) == bufnr
      Schedule(key)
    endif
  endfor
enddef


export def OnCursorMoved(winid: number)
  if internal_change
    return
  endif
  for [key, session] in items(sessions)
    if get(session, 'source_winid', 0) == winid
      UpdateViewport(key)
      UpdateSearch(key)
    endif
  endfor
enddef


export def OnSignsChanged(bufnr: number)
  if internal_change || bufnr <= 0
    return
  endif
  for [key, session] in items(sessions)
    if get(session, 'source_bufnr', -1) == bufnr
      UpdateSigns(key)
      UpdateSearch(key)
    endif
  endfor
enddef


export def OnWinScrolled(winid: number)
  for [key, session] in items(sessions)
    if get(session, 'source_winid', 0) == winid
      UpdateViewport(key)
    elseif get(session, 'winid', 0) == winid
      Schedule(key)
    endif
  endfor
enddef


export def OnResized()
  for key in keys(sessions)
    Schedule(key)
  endfor
enddef


export def OnWinClosed(winid: number)
  if internal_change
    return
  endif
  var minimap_key = string(winid)
  if has_key(sessions, minimap_key)
    DropSession(minimap_key)
    return
  endif

  for [key, session] in items(sessions)
    if get(session, 'source_winid', 0) == winid
      session.pinned = false
      redrawstatus
      var tab_info = WindowInfo(session.winid)
      var replacement = empty(tab_info) ? 0 : FindSourceWindow(tab_info.tabnr)
      if replacement > 0
        session.source_winid = replacement
        session.source_bufnr = WindowInfo(replacement).bufnr
        session.preview_origin = []
        Schedule(key, 0)
      elseif get(g:, 'simpleminimap_auto_close', 0)
        CloseSession(key)
      else
        RenderMessage(key, ['SimpleMinimap', 'no editable window'])
      endif
    endif
  endfor
enddef


def FollowPinnedReplacement(key: string, source_winid: number, wiped_bufnr: number, _timer: number)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if !get(session, 'pinned', false)
        \ || get(session, 'source_winid', 0) != source_winid
        \ || !WindowExists(source_winid)
    return
  endif

  # BufWipeout can run before Vim has installed the alternate buffer in every
  # window that displayed the old one.  Reconcile on the next event-loop turn:
  # the pin belongs to the window, so a normal replacement buffer is adopted
  # without briefly unlocking or letting another split steal the session.
  var info = WindowInfo(source_winid)
  if empty(info) || info.bufnr == wiped_bufnr || !IsEligibleSourceWindow(source_winid)
    return
  endif
  var changed = session.source_bufnr != info.bufnr
  session.source_bufnr = info.bufnr
  session.preview_origin = []
  if changed || empty(session.rows)
    Schedule(key, 0)
  else
    UpdateViewport(key)
  endif
  redrawstatus
enddef


export def OnBufferWipeout(bufnr: number)
  for [key, session] in items(sessions)
    if get(session, 'bufnr', -1) == bufnr
      DropSession(key)
      return
    endif
    if get(session, 'source_bufnr', -1) == bufnr
      if get(session, 'pinned', false) && WindowExists(get(session, 'source_winid', 0))
        var pinned_winid = session.source_winid
        FollowPinnedReplacement(key, pinned_winid, bufnr, 0)
        if has_key(sessions, key)
              \ && get(sessions[key], 'pinned', false)
              \ && get(sessions[key], 'source_bufnr', -1) == bufnr
          timer_start(0, function(FollowPinnedReplacement,
            [key, pinned_winid, bufnr]))
        endif
        continue
      endif
      session.pinned = false
      redrawstatus
      var tab_info = WindowInfo(session.winid)
      var replacement = empty(tab_info) ? 0 : FindSourceWindow(tab_info.tabnr)
      if replacement > 0
        session.source_winid = replacement
        session.source_bufnr = WindowInfo(replacement).bufnr
        session.preview_origin = []
        Schedule(key, 0)
      elseif get(g:, 'simpleminimap_auto_close', 0)
        CloseSession(key)
      else
        RenderMessage(key, ['SimpleMinimap', 'no editable window'])
      endif
    endif
  endfor
enddef


export def Health()
  var daemon = FindDaemon()
  var daemon_version = 'unknown'
  if daemon !=# ''
    try
      var version_output = systemlist(shellescape(daemon) .. ' --version')
      if v:shell_error == 0 && !empty(version_output)
        daemon_version = version_output[0]
      endif
    catch
    endtry
  endif
  var search_supported = exists('*matchbufline')
  var checks = [
    printf('[%s] Vim version: %d', v:version >= 900 ? 'OK' : 'FAIL', v:version),
    printf('[%s] +job / +channel: %d / %d', has('job') && has('channel') ? 'OK' : 'FAIL', has('job'), has('channel')),
    printf('[%s] daemon: %s', daemon ==# '' ? 'FAIL' : 'OK', daemon ==# '' ? 'not found' : daemon),
    printf('[INFO] daemon version: %s', daemon_version),
    printf('[%s] backend: %s, protocol v%d ready=%d', BackendRunning() ? 'OK' : 'INFO', BackendRunning() ? job_status(backend_job) : 'stopped', PROTOCOL_VERSION, backend_ready ? 1 : 0),
    printf('[INFO] backend latency: %s', backend_latency_ms >= 0.0 ? printf('%.1fms', backend_latency_ms) : 'n/a'),
    printf('[%s] search projection: %s', search_supported ? 'OK' : 'INFO', search_supported ? 'matchbufline() available' : 'disabled, needs Vim 9.1.0009+'),
    printf('[%s] density shading: %s', ShadingEnabled() ? 'OK' : 'INFO', ShadingEnabled() ? 'enabled' : (has('textprop') == 1 ? 'disabled by g:simpleminimap_shading' : 'needs +textprop')),
    printf('[INFO] sessions: %d, pending requests: %d', len(sessions), len(requests)),
    printf('[INFO] side/style/sampling: %s / %s / %s', get(g:, 'simpleminimap_side', 'right'), get(g:, 'simpleminimap_render_style', 'braille'), get(g:, 'simpleminimap_sampling', 'adaptive')),
  ]
  for [key, session] in items(sessions)
    var last_render_ms = get(session, 'last_render_ms', -1.0)
    checks->add(printf('[INFO] session %s: %s, renders=%d cache-skips=%d last=%s', key,
      get(session, 'pinned', false) ? 'pinned' : 'following',
      get(session, 'render_count', 0), get(session, 'render_skips', 0),
      last_render_ms >= 0.0 ? printf('%.0fms', last_render_ms) : 'n/a'))
  endfor
  if backend_error !=# ''
    checks->add('[WARN] last backend error: ' .. backend_error)
  endif
  echo join(checks, "\n")
enddef


export def DebugStatus(): dict<any>
  PruneSessions()
  return {
    sessions: deepcopy(sessions),
    backend_path: backend_path,
    backend_running: BackendRunning(),
    backend_ready: backend_ready,
    backend_error: backend_error,
    backend_restart_attempts: backend_restart_attempts,
    backend_latency_ms: backend_latency_ms,
    pending_requests: deepcopy(requests),
  }
enddef


export def Stop()
  for key in keys(sessions)
    var session = sessions[key]
    if get(session, 'timer', 0) > 0
      timer_stop(session.timer)
    endif
  endfor
  StopBackend(false)
  sessions = {}
  requests = {}
  incoming = {}
  backend_restart_attempts = 0
enddef
