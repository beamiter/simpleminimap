vim9script

const PROTOCOL_VERSION = 2
const MIN_RENDER_HEIGHT = 1
const MAX_BACKEND_RESTARTS = 3
const RESTART_WINDOW_MS = 60000.0
# Search projection reads the source buffer through matchbufline() one bounded
# sub-chunk at a time and abandons a row band at its first hit, so a dense
# pattern costs a few hundred lines per row rather than the whole buffer.
# SEARCH_MAX_SCAN_LINES caps the pathological case -- a pattern that matches
# nowhere in a multi-million-line buffer -- and marks the projection partial.
const SEARCH_CHUNK_LINES = 400
const SEARCH_MAX_SCAN_LINES = 200000
# One minimap row covers many source lines, so several overlay entries -- from
# several providers -- routinely land on the same row.  The highest priority
# category wins it: an error and a git "add" on the same row is an error row.
const OVERLAY_PRIORITY = {
  error: 7,
  warning: 6,
  info: 5,
  delete: 4,
  change: 3,
  add: 2,
  mark: 1,
  other: 0,
}
const OVERLAY_GROUPS = {
  error: 'SimpleMinimapSignError',
  warning: 'SimpleMinimapSignWarning',
  info: 'SimpleMinimapSignInfo',
  delete: 'SimpleMinimapSignDelete',
  change: 'SimpleMinimapSignChange',
  add: 'SimpleMinimapSignAdd',
  mark: 'SimpleMinimapMark',
  other: 'SimpleMinimapSign',
}
# Bounds the diff overlay's line probing across all bands of one pass.
const DIFF_MAX_PROBE_LINES = 20000
const DEFAULT_OVERLAYS = ['signs', 'search']
const BUILTIN_OVERLAYS = ['signs', 'search', 'quickfix', 'loclist', 'marks', 'diff']
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
# Restarts are budgeted over a sliding window rather than counted since the
# last success: a daemon that crashes after every render would otherwise reset
# the budget on each success and be respawned every ~100ms for ever.
var backend_restart_window: any = reltime()
var backend_breaker_tripped = false
# Why the breaker tripped: a daemon that keeps crashing and one that keeps
# going silent both spend the same budget, and 'crash loop' is a lie for the
# second one.
var backend_breaker_reason = ''
var backend_timeouts = 0
var consecutive_timeouts = 0
var backend_protocol = 0
# `daemon --version` is probed with a job, never system(): a daemon hung on a
# slow or unresponsive filesystem would otherwise freeze Vim inside the very
# command you run to diagnose a hang.  Keyed by the binary's identity -- path,
# mtime and size -- not by the path alone: ./install.sh rewrites the daemon in
# place, so a path-keyed cache keeps reporting the version the session started
# with for ever, including right after the rebuild :SimpleMinimapHealth itself
# told the user to perform.
var daemon_version_probed = ''
var daemon_version = ''
var daemon_version_job: any = v:null
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
  if winid <= 0
    return false
  endif
  var tabwin = win_id2tabwin(winid)
  if len(tabwin) >= 2 && tabwin[0] > 0 && tabwin[1] > 0
    return true
  endif
  # A popup window belongs to no tab page's window list, so win_id2tabwin()
  # reports [0, 0] for a perfectly live one.  In 'popup' display mode the
  # minimap *is* a popup, and every liveness check in here runs through this.
  if has('popupwin')
    try
      return !empty(popup_getpos(winid))
    catch
    endtry
  endif
  return false
enddef


def DisplayMode(): string
  return get(g:, 'simpleminimap_display', 'split') ==# 'popup' && has('popupwin')
    ? 'popup'
    : 'split'
enddef


def IsPopupSession(session: dict<any>): bool
  return get(session, 'kind', 'split') ==# 'popup'
enddef


# Which tab page a session belongs to.  A split minimap is in the tab that
# holds its window; a popup is in no window list at all, so it inherits the tab
# of the window it is tracking -- derived rather than stored, because tab
# numbers shift whenever a tab is closed.
def SessionTab(session: dict<any>): number
  if !IsPopupSession(session)
    var split_info = WindowInfo(get(session, 'winid', 0))
    return empty(split_info) ? 0 : get(split_info, 'tabnr', 0)
  endif
  var info = WindowInfo(get(session, 'source_winid', 0))
  if !empty(info)
    # Remembered as well as derived: while the tracked window is being closed
    # the session would otherwise report no tab at all, become unreachable
    # through CurrentSessionKey(), and never get the replacement window that
    # would have repaired it.
    session.tabnr = get(info, 'tabnr', 0)
    return session.tabnr
  endif
  return get(session, 'tabnr', 0)
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


def StopRequestTimer(session: dict<any>)
  if get(session, 'request_timer', 0) > 0
    timer_stop(session.request_timer)
  endif
  session.request_timer = 0
enddef


def StopAllRequestTimers()
  for session in values(sessions)
    StopRequestTimer(session)
  endfor
enddef


def ForgetRequestsForSession(key: string)
  if has_key(sessions, key)
    StopRequestTimer(sessions[key])
  endif
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
  StopRequestTimer(session)
  ClearMatches(key)
  sessions->remove(key)
  ForgetRequestsForSession(key)
  ReleaseUnusedListeners()
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
    if SessionTab(session) == tabnr
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
    StopRequestTimer(session)
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
    backend_protocol = len(fields) == 2 ? str2nr(fields[1]) : 0
    backend_ready = len(fields) == 2 && backend_protocol == PROTOCOL_VERSION
    if !backend_ready
      # By far the most common cause is a plugin update that did not rebuild
      # lib/, so name the fix instead of only naming the symptom: "protocol
      # version mismatch" in an 18-column window tells nobody what to do.
      backend_error = printf(
        'daemon speaks protocol v%d, this plugin expects v%d; run ./install.sh, then :SimpleMinimapRestart',
        backend_protocol, PROTOCOL_VERSION)
      for key in keys(sessions)
        RenderMessage(key, ['SimpleMinimap', 'daemon is', 'out of date', 'run install.sh'])
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


# The one place a restart is paid for.  Every automatic respawn -- a crash, a
# daemon that stopped answering -- goes through here, so three restarts per
# rolling window is a total, not a total per failure mode.  Returns false once
# the budget is spent, having tripped the breaker.
def ConsumeRestartBudget(reason: string): bool
  if reltimefloat(reltime(backend_restart_window)) * 1000.0 > RESTART_WINDOW_MS
    backend_restart_attempts = 0
    backend_restart_window = reltime()
  endif
  if backend_restart_attempts < MAX_BACKEND_RESTARTS
    backend_restart_attempts += 1
    return true
  endif
  # Report it once and stop, rather than forking a process every 100ms for
  # the rest of the session.  :SimpleMinimapRestart re-arms the breaker.
  backend_breaker_tripped = true
  backend_breaker_reason = reason
  Log(printf('crash-loop breaker tripped after %d restarts (%s)',
    backend_restart_attempts, reason))
  return false
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
  StopAllRequestTimers()
  backend_stopping = false
  backend_restart_requested = false
  Log(backend_error)
  var should_restart = explicitly_requested
  if unexpected && get(g:, 'simpleminimap_auto_restart', 1)
    should_restart = ConsumeRestartBudget('crash loop')
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
      RenderMessage(key, backend_breaker_tripped
        ? ['SimpleMinimap backend stopped', backend_breaker_reason, ':SimpleMinimapRestart']
        : ['SimpleMinimap backend stopped', backend_error])
    endfor
  endif
enddef


def DaemonVersionOut(_channel: channel, message: string)
  if daemon_version ==# '' && message !=# ''
    daemon_version = message
  endif
enddef


def DaemonVersionExit(exited_job: job, _status: number)
  # A re-probe can start before the previous probe's exit callback arrives;
  # clearing the handle unconditionally would then hide the live job and make
  # Health report "not probed yet" while a probe is in flight.
  if type(daemon_version_job) != v:t_job || daemon_version_job == exited_job
    daemon_version_job = v:null
  endif
enddef


# What "the same daemon" means for the version cache.  getftime()/getfsize()
# both change when install.sh drops a freshly built binary over the old one,
# and either alone can miss it: mtime has one-second resolution, and a rebuild
# of unchanged sources can keep the size.
def DaemonStamp(path: string): string
  return printf('%s|%d|%d', path, getftime(path), getfsize(path))
enddef


def ForgetDaemonVersion()
  daemon_version_probed = ''
  daemon_version = ''
  if type(daemon_version_job) == v:t_job
    try
      job_stop(daemon_version_job)
    catch
    endtry
  endif
  daemon_version_job = v:null
enddef


def ProbeDaemonVersion(path: string)
  if path ==# ''
    return
  endif
  var stamp = DaemonStamp(path)
  if daemon_version_probed ==# stamp
    return
  endif
  # DaemonVersionOut() keeps the first answer it sees, so a probe still in
  # flight for the previous binary would otherwise win the race and reinstate
  # the stale version this call exists to replace.
  if type(daemon_version_job) == v:t_job
    try
      job_stop(daemon_version_job)
    catch
    endtry
  endif
  daemon_version_probed = stamp
  daemon_version = ''
  try
    daemon_version_job = job_start([path, '--version'], {
      in_io: 'null',
      out_mode: 'nl',
      out_cb: DaemonVersionOut,
      exit_cb: DaemonVersionExit,
      stoponexit: 'kill',
    })
  catch
    daemon_version_job = v:null
  endtry
enddef


def StartBackend(): bool
  if BackendRunning()
    return true
  endif
  if backend_stopping
    backend_error = 'backend is restarting'
    return false
  endif
  # Every render path reaches this function, so the breaker has to hold here
  # too -- otherwise "stop trying" would only mean "stop trying on a timer" and
  # the next keystroke would fork the doomed process all over again.
  if backend_breaker_tripped
    backend_error = 'backend crash loop; run :SimpleMinimapRestart'
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
  ProbeDaemonVersion(backend_path)
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
  StopAllRequestTimers()
  # :SimpleMinimapRestart is the documented remedy for a stale daemon, so it
  # has to invalidate what we believe about the binary too -- the stamp check
  # in ProbeDaemonVersion() covers a rebuild in place, but not a
  # g:simpleminimap_daemon_path repointed at a different build of the same age
  # and size.
  ForgetDaemonVersion()
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


# ---------------------------------------------------------------------------
# Incremental sampling.
#
# A render used to re-read the whole buffer: RepresentativeSample() calls
# SampleText() three times per band and BuildSampleGroup() calls it for four
# bands, i.e. up to 12 getbufline() + NormalizeDisplayCells() pairs per minimap
# row -- 720 of them on a 60-row minimap -- and typing one character in one
# line paid all of it again, every debounce tick, on the main thread.  On a CJK
# or emoji-heavy file NormalizeDisplayCells() leaves its ASCII fast path and
# walks the line character by character, which turns that into tens of
# thousands of function calls per keystroke.
#
# Nothing outside the edited line can have changed, so cache the normalised
# samples per band and let a buffer listener invalidate exactly the bands the
# edit touched.  A keystroke inside one band then costs 12 samples instead of
# 720.
# ---------------------------------------------------------------------------
const SAMPLE_CACHE_MAX_ENTRIES = 4000
var sample_caches: dict<any> = {}
var sample_listeners: dict<number> = {}
var sample_cache_hits = 0
var sample_cache_misses = 0

def IncrementalEnabled(): bool
  return get(g:, 'simpleminimap_incremental', 1) != 0 && exists('*listener_add')
enddef


def OnBufferListen(bufnr: number, start: number, end: number, added: number, _changes: list<any>)
  var key = string(bufnr)
  if !has_key(sample_caches, key)
    return
  endif
  if added != 0
    # Adding or removing lines moves every band below the edit *and* changes
    # the band boundaries themselves, because they are derived from the line
    # count.  Nothing in the cache survives that.
    sample_caches[key].entries = {}
    return
  endif
  # `end` is the line below the last changed one.
  var entries = sample_caches[key].entries
  for entry_key in keys(entries)
    var bounds = split(entry_key, ':')
    if str2nr(bounds[0]) < end && str2nr(bounds[1]) >= start
      entries->remove(entry_key)
    endif
  endfor
enddef


def EnsureBufferListener(bufnr: number)
  var key = string(bufnr)
  if has_key(sample_listeners, key) || bufnr <= 0
    return
  endif
  try
    sample_listeners[key] = listener_add(OnBufferListen, bufnr)
  catch
    Log(printf('could not watch buffer %d: %s', bufnr, v:exception))
  endtry
enddef


def ReleaseBufferListener(bufnr: number)
  var key = string(bufnr)
  if has_key(sample_listeners, key)
    try
      listener_remove(sample_listeners[key])
    catch
    endtry
    sample_listeners->remove(key)
  endif
  if has_key(sample_caches, key)
    sample_caches->remove(key)
  endif
enddef


# Called after anything that can drop a session: a listener on a buffer no
# session tracks any more is a leak that keeps firing for the rest of the
# session.
def ReleaseUnusedListeners()
  var live: dict<bool> = {}
  for session in values(sessions)
    live[string(get(session, 'source_bufnr', -1))] = true
  endfor
  for key in keys(sample_listeners)
    if !has_key(live, key)
      ReleaseBufferListener(str2nr(key))
    endif
  endfor
enddef


def SampleCacheEntries(bufnr: number, config: string): dict<any>
  var key = string(bufnr)
  if !has_key(sample_caches, key) || sample_caches[key].config !=# config
    sample_caches[key] = {config: config, entries: {}}
  endif
  # Resizing the window or the minimap leaves band keys nothing will ever ask
  # for again; a hard cap is cheaper than tracking which ones are still live.
  if len(sample_caches[key].entries) > SAMPLE_CACHE_MAX_ENTRIES
    sample_caches[key].entries = {}
  endif
  return sample_caches[key].entries
enddef


export def SampleCacheStats(): dict<number>
  return {
    hits: sample_cache_hits,
    misses: sample_cache_misses,
    buffers: len(sample_listeners),
  }
enddef


# How many minimap rows a buffer of this many lines gets in a window this tall.
#
# 'compact' is the historical fixed scale of four source lines per row, which
# means any file shorter than four times the minimap height rendered into the
# top fraction of the window and left the rest blank -- a 40-line file in a
# 50-row minimap drew 10 rows and 40 dead ones, the viewport highlight covered
# the whole drawn block wherever you were, and the scroll position said
# nothing.  Most files people edit are shorter than that, so it was the default
# experience on a tall terminal.  'proportional' spends the window it has: one
# row per line until the rows run out.
def RowCountFor(height: number, source_lines: number): number
  if get(g:, 'simpleminimap_fill', 'proportional') ==# 'compact'
    return min([height, max([1, (source_lines + 3) / 4])])
  endif
  return min([height, max([1, source_lines])])
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
  var row_count = RowCountFor(height, source_lines)
  var max_columns = Clamp(get(g:, 'simpleminimap_max_columns', 120), 20, 1000)
  var tabstop = Clamp(getbufvar(session.source_bufnr, '&tabstop'), 1, 64)
  var style = get(g:, 'simpleminimap_render_style', 'braille')
  if index(['braille', 'blocks', 'ascii'], style) < 0
    style = 'braille'
  endif

  var incremental = IncrementalEnabled()
  var entries: dict<any> = {}
  if incremental
    EnsureBufferListener(session.source_bufnr)
    # Listener callbacks are queued until a redraw or an explicit flush, and
    # this runs from a timer.  Without the flush the cache would still be
    # holding the samples from before the keystroke that scheduled the render,
    # and the minimap would show pre-edit text with a matching signature --
    # i.e. it would never correct itself.
    try
      listener_flush(session.source_bufnr)
    catch
    endtry
    entries = SampleCacheEntries(session.source_bufnr,
      printf('%d|%d|%s', max_columns, tabstop,
        get(g:, 'simpleminimap_sampling', 'adaptive')))
    # :SimpleMinimapRefresh! is the documented way to say "I do not trust what
    # I am looking at", so it has to reach past the cache as well.
    if get(session, 'force_render', false)
      entries->filter((_, _v) => false)
    endif
  endif

  var groups: list<string> = []
  for row_index in range(0, row_count - 1)
    var start_zero = (row_index * source_lines) / row_count
    var end_zero = (((row_index + 1) * source_lines) / row_count) - 1
    var start_line = start_zero + 1
    var end_line = max([start_line, end_zero + 1])
    var cache_key = printf('%d:%d', start_line, end_line)
    var samples: list<string>
    if incremental && has_key(entries, cache_key)
      samples = entries[cache_key]
      sample_cache_hits += 1
    else
      samples = BuildSampleGroup(session.source_bufnr, start_line, end_line, max_columns, tabstop)
      sample_cache_misses += 1
      if incremental
        entries[cache_key] = samples
      endif
    endif
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
  # A popup is sized to the window it floats over, and BuildRequestBody() asks
  # the surface how many rows it has, so the move has to happen first.
  if !RepositionSurface(key)
    RenderMessage(key, ['SimpleMinimap', 'no editable window'])
    return
  endif
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
    UpdateOverlays(key)
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
    return
  endtry

  # A daemon that accepts input but stops replying -- wedged, SIGSTOPped, stuck
  # on a slow filesystem -- used to leave the minimap showing pre-edit content
  # forever while job_status() still said "run" and Health still said [OK].
  # Nothing else in the pipeline has a deadline, so arm one here.
  var timeout = RequestTimeoutMs()
  if timeout > 0
    session.request_timer = timer_start(timeout,
      function(ExpireRequest, [key, request_id]))
  endif
enddef


def RequestTimeoutMs(): number
  var configured = get(g:, 'simpleminimap_request_timeout_ms', 5000)
  if type(configured) != v:t_number || configured <= 0
    return 0
  endif
  return Clamp(configured, 100, 600000)
enddef


def ExpireRequest(key: string, request_id: number, _timer: number)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  session.request_timer = 0
  if get(session, 'request_id', 0) != request_id
    return
  endif
  backend_timeouts += 1
  consecutive_timeouts += 1
  var message = printf('backend did not respond in %dms', RequestTimeoutMs())
  Log(printf('request %d timed out (%d consecutive)', request_id, consecutive_timeouts))
  RejectResponse(string(request_id), message)
  # One timeout can be a slow machine under load; two in a row means the daemon
  # is not coming back, and only a fresh process recovers from that.
  if consecutive_timeouts >= 2
    consecutive_timeouts = 0
    RestartUnresponsiveBackend()
  endif
enddef


# Restarting a wedged daemon used to go through the user-facing Restart(),
# which clears backend_restart_attempts, backend_restart_window and
# backend_breaker_tripped -- so timeout restarts were completely unbudgeted,
# refunded any crash budget already spent, and respawned the daemon even when
# g:simpleminimap_auto_restart was 0.  A daemon that answers the handshake and
# then goes silent forked a new process every couple of deadlines for the life
# of the session.  Timeouts now spend the same rolling budget as crashes.
def RestartUnresponsiveBackend()
  if !get(g:, 'simpleminimap_auto_restart', 1)
    # The user asked for no automatic respawn.  Leave the wedged process
    # alone: killing it here would only make the next render start a
    # replacement through StartBackend(), which is the respawn they disabled.
    Log('not restarting an unresponsive backend: g:simpleminimap_auto_restart is 0')
    return
  endif
  if !ConsumeRestartBudget('no response')
    # Budget spent.  Stop the wedged process instead of replacing it; the
    # breaker keeps StartBackend() from forking another one, and BackendExit()
    # reports why.
    StopBackend(false)
    return
  endif
  Log('restarting a wedged backend after repeated request timeouts')
  for key in keys(sessions)
    RenderMessage(key, ['SimpleMinimap', 'restarting backend…'])
  endfor
  StopBackend(true)
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


# ---------------------------------------------------------------------------
# Overlay providers.
#
# Everything painted on top of the rendered rows -- signs, quickfix entries,
# marks, diff hunks -- has the same shape: source line numbers carrying a
# severity-like category.  One registry instead of one bespoke routine per
# source means a new source is a function, and it means a sibling plugin can
# feed the minimap without first turning its state into Vim signs.  Signs were
# the only channel before, which forced every producer into the sign column
# whether the user wanted it there or not, and left `:grep` results, the
# location list, marks and `:diffthis` invisible.
#
# A provider is called with a context dictionary:
#   bufnr  the source buffer number
#   winid  the source window ID
#   rows   the row bands currently rendered, [{start, end}, ...]
# and returns a list of {lnum, category} dictionaries.  Unknown categories fall
# back to 'other'; a provider that throws is logged and skipped rather than
# allowed to break the redraw that called it.
# ---------------------------------------------------------------------------
var overlay_providers: dict<any> = {}
var overlay_order: list<string> = []

export def RegisterOverlay(name: string, Provider: func, opts: dict<any> = {})
  if name ==# ''
    return
  endif
  if !has_key(overlay_providers, name)
    overlay_order->add(name)
  endif
  overlay_providers[name] = {Provider: Provider, opts: opts}
enddef


# Every overlay name this plugin knows how to draw, registration order first.
# 'search' is not a row provider -- it has its own bounded band scan and its own
# invalidation key -- but it is configured through the same list, so it belongs
# in the answer.
export def OverlayNames(): list<string>
  var names = copy(overlay_order)
  if index(names, 'search') < 0
    names->add('search')
  endif
  return names
enddef


def ConfiguredOverlays(): list<string>
  var configured = get(g:, 'simpleminimap_overlays', DEFAULT_OVERLAYS)
  return type(configured) == v:t_list ? configured : DEFAULT_OVERLAYS
enddef


export def OverlayEnabled(name: string): bool
  return index(ConfiguredOverlays(), name) >= 0
enddef


def SignsOverlay(context: dict<any>): list<dict<any>>
  # Kept as a separate switch from the overlay list: turning signs off is the
  # documented meaning of this option and predates the registry.
  if !get(g:, 'simpleminimap_show_signs', 1)
    return []
  endif
  var placed: list<any> = []
  try
    placed = sign_getplaced(context.bufnr, {group: '*'})
  catch
    Log('could not read source signs: ' .. v:exception)
    return []
  endtry
  if empty(placed) || empty(get(placed[0], 'signs', []))
    return []
  endif
  var entries: list<dict<any>> = []
  for sign in placed[0].signs
    entries->add({
      lnum: get(sign, 'lnum', 0),
      category: SignCategory(get(sign, 'name', '')),
    })
  endfor
  return entries
enddef


def QuickfixCategory(entry: dict<any>): string
  var kind = toupper(get(entry, 'type', ''))
  if kind ==# 'E'
    return 'error'
  elseif kind ==# 'W'
    return 'warning'
  elseif kind ==# 'I' || kind ==# 'N'
    return 'info'
  endif
  return 'other'
enddef


def QuickfixEntries(items: list<any>, bufnr: number): list<dict<any>>
  var entries: list<dict<any>> = []
  for item in items
    if get(item, 'bufnr', 0) != bufnr || get(item, 'valid', 0) == 0
      continue
    endif
    var lnum = get(item, 'lnum', 0)
    if lnum > 0
      entries->add({lnum: lnum, category: QuickfixCategory(item)})
    endif
  endfor
  return entries
enddef


def QuickfixOverlay(context: dict<any>): list<dict<any>>
  return QuickfixEntries(getqflist(), context.bufnr)
enddef


def LoclistOverlay(context: dict<any>): list<dict<any>>
  if context.winid <= 0
    return []
  endif
  return QuickfixEntries(getloclist(context.winid), context.bufnr)
enddef


# Only the marks a user sets deliberately: 'a-'z in this buffer and 'A-'Z that
# point at this file.  The automatic ones ('. '^ '" '[ ']) move on every edit
# and would turn the overview into noise that changes as you type.
def MarksOverlay(context: dict<any>): list<dict<any>>
  if !exists('*getmarklist')
    return []
  endif
  var entries: list<dict<any>> = []
  for mark in getmarklist(context.bufnr)
    var pos = get(mark, 'pos', [])
    if get(mark, 'mark', '') =~# "^'[a-z]$" && len(pos) >= 2 && pos[1] > 0
      entries->add({lnum: pos[1], category: 'mark'})
    endif
  endfor
  var file = fnamemodify(bufname(context.bufnr), ':p')
  if file ==# ''
    return entries
  endif
  for mark in getmarklist()
    var pos = get(mark, 'pos', [])
    if get(mark, 'mark', '') =~# "^'[A-Z]$" && len(pos) >= 2 && pos[1] > 0
        && fnamemodify(get(mark, 'file', ''), ':p') ==# file
      entries->add({lnum: pos[1], category: 'mark'})
    endif
  endfor
  return entries
enddef


def DiffCategory(id: any): string
  if type(id) != v:t_number || id <= 0
    return ''
  endif
  var name = synIDattr(id, 'name')
  if name =~? 'DiffAdd'
    return 'add'
  elseif name =~? 'DiffDelete'
    return 'delete'
  endif
  return 'change'
enddef


# Answers "does anything in this band differ, and how" for each band, running
# inside the source window because diff_hlID() only ever answers for the
# current one.  Exported so the legacy context win_execute() creates can name
# it; it is an implementation detail of the diff overlay, not public API.
#
# Each band is left at its first hit, exactly as the search projection is, so
# the usual case costs a handful of probes per band; the shared budget bounds
# the pathological one (two identical files in diff mode, where no band ever
# hits and every line is visited).
export def DiffProbe(bands: list<any>): list<string>
  var result: list<string> = []
  var budget = DIFF_MAX_PROBE_LINES
  var last = line('$')
  for band in bands
    var category = ''
    var line_number = band[0]
    var band_end = min([band[1], last])
    while line_number <= band_end && budget > 0
      budget -= 1
      category = DiffCategory(diff_hlID(line_number, 1))
      if category !=# ''
        break
      endif
      line_number += 1
    endwhile
    result->add(category)
  endfor
  return result
enddef


# Lines deleted relative to the other buffer are drawn as filler, which has no
# line number here, so a pure deletion shows up on neither side's minimap --
# the same thing you see in the diff itself.
def DiffOverlay(context: dict<any>): list<dict<any>>
  var winid = context.winid
  if winid <= 0 || !getwinvar(winid, '&diff', false) || empty(context.rows)
    return []
  endif
  var bands: list<any> = []
  for row in context.rows
    bands->add([row.start, row.end])
  endfor
  var decoded: list<any> = []
  try
    var raw = win_execute(winid,
      printf('echo json_encode(simpleminimap#DiffProbe(%s))', string(bands)))
    decoded = json_decode(trim(raw))
  catch
    Log('diff overlay failed: ' .. v:exception)
    return []
  endtry
  var entries: list<dict<any>> = []
  for index in range(min([len(decoded), len(context.rows)]))
    if type(decoded[index]) == v:t_string && decoded[index] !=# ''
      entries->add({lnum: context.rows[index].start, category: decoded[index]})
    endif
  endfor
  return entries
enddef


RegisterOverlay('signs', SignsOverlay)
RegisterOverlay('quickfix', QuickfixOverlay)
RegisterOverlay('loclist', LoclistOverlay)
RegisterOverlay('marks', MarksOverlay)
RegisterOverlay('diff', DiffOverlay)


def CollectOverlayEntries(session: dict<any>): list<dict<any>>
  var context = {
    bufnr: session.source_bufnr,
    winid: get(session, 'source_winid', 0),
    rows: session.rows,
  }
  var entries: list<dict<any>> = []
  var configured = ConfiguredOverlays()
  for name in overlay_order
    if index(configured, name) < 0
      continue
    endif
    # Invoked directly, never through call(): call() resolves a Funcref built
    # by a legacy `function('Name')` against *this* Vim9 script's namespace,
    # where a global function is not visible under its bare name, so every
    # third-party provider would fail with E117.
    var Provider: func = overlay_providers[name].Provider
    try
      entries += Provider(context)
    catch
      Log(printf('overlay provider %s failed: %s', name, v:exception))
    endtry
  endfor
  return entries
enddef


def UpdateOverlays(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  ClearSignMatches(key)
  if !WindowExists(session.winid)
      || empty(session.rows)
      || !bufexists(session.source_bufnr)
    return
  endif

  var row_category: dict<string> = {}
  # A file can carry thousands of signs or quickfix entries projected onto a
  # few dozen rows, so stop as soon as every row has reached the category
  # nothing can outrank.
  var settled = 0
  var row_count = len(session.rows)
  for entry in CollectOverlayEntries(session)
    var source_line = get(entry, 'lnum', 0)
    if source_line < 1
      continue
    endif
    var minimap_row = RowForSourceLine(session.rows, source_line)
    if minimap_row <= 0
      continue
    endif
    var category = get(entry, 'category', 'other')
    if !has_key(OVERLAY_PRIORITY, category)
      category = 'other'
    endif
    var row_key = string(minimap_row)
    var existing = get(row_category, row_key, '')
    if existing ==# '' || OVERLAY_PRIORITY[category] > OVERLAY_PRIORITY[existing]
      row_category[row_key] = category
      if category ==# 'error'
        settled += 1
        if settled >= row_count
          break
        endif
      endif
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
    session.sign_matches->add(matchaddpos(OVERLAY_GROUPS[category], sort(rows, 'n'), 15, -1, {window: session.winid}))
  endfor
enddef


def UpdateSearch(key: string, force: bool = false)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var supported = exists('*matchbufline')
  var enabled = supported && get(g:, 'simpleminimap_show_search', 1)
    && OverlayEnabled('search')
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
  session.search_partial = false
  if !enabled || !v:hlsearch || @/ ==# ''
      || empty(session.rows)
      || !WindowExists(session.winid)
      || !bufexists(session.source_bufnr)
    return
  endif

  var projected = SearchRows(session, @/)
  session.search_rows = projected[0]
  session.search_partial = projected[1]
  if !empty(session.search_rows)
    session.search_match = matchaddpos('SimpleMinimapSearch', session.search_rows,
      12, -1, {window: session.winid})
  endif
enddef


# Projecting search matches needs exactly one bit per minimap row: does any
# line in this row's band match?  Asking matchbufline() for every match in the
# buffer instead -- as this used to -- materialises one dictionary per
# *occurrence*, so a common pattern on a large file allocates millions of them
# on the main thread inside a CursorMoved autocommand, to produce at most
# len(rows) distinct row numbers.  Walk the bands and leave each one at its
# first hit, in sub-chunks so that a dense pattern cannot allocate a whole
# band's worth of matches either.  Returns [rows, partial].
def SearchRows(session: dict<any>, pattern: string): list<any>
  var rows = session.rows
  var info = getbufinfo(session.source_bufnr)
  var last_line = empty(info) ? 0 : get(info[0], 'linecount', 0)
  var marked: list<number> = []
  # The buffer can have shrunk since the render these rows describe.
  var budget = SEARCH_MAX_SCAN_LINES
  for index in range(len(rows))
    var line = rows[index].start
    var row_end = min([rows[index].end, last_line])
    while line <= row_end
      if budget <= 0
        return [marked, true]
      endif
      var chunk_end = min([row_end, line + SEARCH_CHUNK_LINES - 1])
      budget -= chunk_end - line + 1
      var found: list<any> = []
      try
        found = matchbufline(session.source_bufnr, pattern, line, chunk_end)
      catch
        return [marked, true]
      endtry
      if !empty(found)
        marked->add(index + 1)
        break
      endif
      line = chunk_end + 1
    endwhile
  endfor
  return [marked, false]
enddef


# The row ranges are contiguous, ascending and generated by BuildRequestBody()
# as start = (i * source_lines) / row_count, so the exact inverse is one
# division.  Verify the guess rather than trusting the shape of data that
# crossed the wire, and fall back to a binary search: the linear scan this
# replaces ran once per sign, i.e. O(signs x rows) on every CursorHold.
def RowForSourceLine(rows: list<any>, source_line: number): number
  var count = len(rows)
  if count == 0
    return 0
  endif
  if source_line <= rows[0].start
    return 1
  endif
  if source_line >= rows[count - 1].end
    return count
  endif

  var span = rows[count - 1].end - rows[0].start + 1
  var guess = ((source_line - rows[0].start) * count) / span
  if guess >= 0 && guess < count
      && source_line >= rows[guess].start && source_line <= rows[guess].end
    return guess + 1
  endif

  var low = 0
  var high = count - 1
  while low < high
    var middle = (low + high) / 2
    if source_line > rows[middle].end
      low = middle + 1
    else
      high = middle
    endif
  endwhile
  return low + 1
enddef


# The minimap rows covered by the source window's visible range: the "thumb"
# of the scrollbar.  Returns [0, 0] when there is nothing to project.
def ViewportRows(session: dict<any>): list<number>
  if empty(get(session, 'rows', [])) || !WindowExists(get(session, 'source_winid', 0))
    return [0, 0]
  endif
  var source_info = WindowInfo(session.source_winid)
  if empty(source_info)
    return [0, 0]
  endif
  var top_line = max([1, get(source_info, 'topline', 1)])
  var bottom_line = max([top_line, get(source_info, 'botline', top_line)])
  return [RowForSourceLine(session.rows, top_line),
    RowForSourceLine(session.rows, bottom_line)]
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
  var cursor_pos = getcurpos(session.source_winid)
  var cursor_line = len(cursor_pos) > 1 ? cursor_pos[1] : top_line
  var band = ViewportRows(session)
  var first_row = band[0]
  var last_row = band[1]
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
  # Deliberately does NOT reset backend_restart_attempts: that turned the
  # three-restart cap into a per-success cap, so a daemon crashing after every
  # render was respawned without limit.  The restart budget is a sliding
  # window in BackendExit(); only an explicit :SimpleMinimapRestart clears it.
  StopRequestTimer(session)
  consecutive_timeouts = 0
  backend_error = ''
  SetBufferLines(session.bufnr, output)
  ApplyShading(key, output)
  UpdateOverlays(key)
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
  if IsPopupSession(sessions[string(winid)])
    return
  endif
  ApplyWindowOptions(winid)
enddef


# Where a popup minimap sits: flush against the tracked window's edge, the full
# height of that window.  Screen coordinates, because a popup is positioned on
# the screen rather than inside the window layout.
def PopupGeometry(source_winid: number): dict<any>
  var winnr = win_id2win(source_winid)
  if winnr <= 0
    return {}
  endif
  var origin = win_screenpos(winnr)
  if len(origin) < 2 || origin[0] <= 0
    return {}
  endif
  var available = winwidth(winnr)
  var height = winheight(winnr)
  if available <= 0 || height <= 0
    return {}
  endif
  # Never take the whole window: a minimap wider than the code it covers is a
  # curtain, not an overview.
  var width = Clamp(get(g:, 'simpleminimap_width', 18), 1, max([1, available - 1]))
  var col = get(g:, 'simpleminimap_side', 'right') ==# 'left'
    ? origin[1]
    : origin[1] + available - width
  return {line: origin[0], col: col, width: width, height: height}
enddef


# A popup does not move with the window it floats over, so every event that can
# change the layout has to put it back.  Returns false when the surface could
# not be placed, which is how a source window that has gone away is noticed.
def RepositionSurface(key: string): bool
  if !has_key(sessions, key)
    return false
  endif
  var session = sessions[key]
  if !IsPopupSession(session)
    return true
  endif
  if !WindowExists(session.winid)
    return false
  endif
  var geometry = PopupGeometry(get(session, 'source_winid', 0))
  if empty(geometry)
    popup_hide(session.winid)
    return false
  endif
  popup_move(session.winid, {
    line: geometry.line,
    col: geometry.col,
    minwidth: geometry.width,
    maxwidth: geometry.width,
    minheight: geometry.height,
    maxheight: geometry.height,
  })
  popup_show(session.winid)
  return true
enddef


export def RepositionSurfaces()
  for key in keys(sessions)
    RepositionSurface(key)
  endfor
enddef


def ConfigureMinimapWindow(winid: number, bufnr: number, kind: string = 'split')
  win_execute(winid, 'setlocal nowrap nonumber norelativenumber nocursorcolumn nocursorline')
  win_execute(winid, 'setlocal signcolumn=no foldcolumn=0 nofoldenable nolist')
  win_execute(winid, 'setlocal scrolloff=0 sidescrolloff=0')
  win_execute(winid, 'setlocal filetype=simpleminimap')
  setbufvar(bufnr, '&modifiable', 0)
  setbufvar(bufnr, '&modified', 0)
  if kind ==# 'popup'
    # A popup is never entered, so there is nothing to map into and no
    # window-local 'statusline' to defend: the popup's own `highlight` option
    # carries what 'wincolor' carries for a split.
    return
  endif
  win_execute(winid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodeline undolevels=-1')
  ApplyWindowOptions(winid)

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

  var kind = DisplayMode()
  var minimap_winid = 0
  var minimap_bufnr = 0
  var opened_key = ''
  internal_change = true
  try
    if kind ==# 'popup'
      var geometry = PopupGeometry(source_winid)
      if empty(geometry)
        throw 'the tracked window has no usable geometry'
      endif
      # A popup needs a buffer that is not displayed anywhere else, and
      # bufhidden=wipe would take it away the moment the popup is hidden on a
      # tab switch, so this one is owned and wiped by CloseSession() instead.
      minimap_bufnr = bufadd(printf('simpleminimap://popup/%d', localtime() + source_winid))
      bufload(minimap_bufnr)
      setbufvar(minimap_bufnr, '&buftype', 'nofile')
      setbufvar(minimap_bufnr, '&swapfile', 0)
      setbufvar(minimap_bufnr, '&buflisted', 0)
      setbufvar(minimap_bufnr, '&undolevels', -1)
      minimap_winid = popup_create(minimap_bufnr, {
        line: geometry.line,
        col: geometry.col,
        minwidth: geometry.width,
        maxwidth: geometry.width,
        minheight: geometry.height,
        maxheight: geometry.height,
        zindex: 50,
        wrap: false,
        scrollbar: false,
        mapping: false,
        highlight: 'SimpleMinimapNormal',
      })
    else
      if get(g:, 'simpleminimap_side', 'right') ==# 'left'
        topleft vertical new
      else
        botright vertical new
      endif
      minimap_winid = win_getid()
      execute 'vertical resize ' .. get(g:, 'simpleminimap_width', 18)
      minimap_bufnr = bufnr()
    endif
    var key = string(minimap_winid)
    opened_key = key
    sessions[key] = {
      kind: kind,
      tabnr: tabnr,
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
      search_partial: false,
      search_state: [],
      preview_origin: [],
      drag_anchor: {},
      last_scroll: [],
      request_timer: 0,
      request_started: [],
      request_signature: '',
      last_signature: '',
      force_render: false,
      render_count: 0,
      render_skips: 0,
      last_render_ms: -1.0,
    }
    ConfigureMinimapWindow(minimap_winid, minimap_bufnr, kind)
    SetBufferLines(minimap_bufnr, ['SimpleMinimap starting…'])
    if kind !=# 'popup'
      win_gotoid(source_winid)
    endif
    Schedule(key, 0)
  catch
    if opened_key !=# '' && has_key(sessions, opened_key)
      DropSession(opened_key)
    endif
    if kind ==# 'popup'
      if minimap_winid > 0
        popup_close(minimap_winid)
      endif
      if minimap_bufnr > 0 && bufexists(minimap_bufnr)
        execute 'bwipeout!' minimap_bufnr
      endif
    elseif WindowExists(minimap_winid) && winnr('$') > 1
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
  if empty(session)
    return
  endif
  if IsPopupSession(session)
    # The popup owns its buffer -- nothing else displays it -- so closing the
    # popup has to take the buffer with it or every toggle leaks one.
    if WindowExists(session.winid)
      popup_close(session.winid)
    endif
    if bufexists(get(session, 'bufnr', -1))
      execute 'bwipeout!' session.bufnr
    endif
    return
  endif
  if !WindowExists(session.winid)
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
  highlight default link SimpleMinimapMark Identifier
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
    if !WindowExists(get(session, 'winid', 0))
      continue
    endif
    if IsPopupSession(session)
      # A popup has no window-local options to restore; its colour comes from
      # the `highlight` argument, which follows the re-linked group by name.
      continue
    endif
    ApplyWindowOptions(session.winid)
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
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  if IsPopupSession(sessions[key])
    # Vim cannot move the cursor into a popup, so say so instead of silently
    # doing nothing and leaving the user pressing the key again.
    echohl WarningMsg
    echom "[SimpleMinimap] a popup minimap cannot be focused; "
      .. "set g:simpleminimap_display = 'split' for an enterable window."
    echohl None
    return
  endif
  win_gotoid(sessions[key].winid)
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
      if IsPopupSession(sessions[key])
        RepositionSurface(key)
      else
        win_execute(sessions[key].winid, 'vertical resize ' .. width)
      endif
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
  # The documented way back after repeated failures: clear the crash-loop
  # breaker and the timeout streak along with the restart budget.
  backend_restart_attempts = 0
  backend_restart_window = reltime()
  backend_breaker_tripped = false
  backend_breaker_reason = ''
  consecutive_timeouts = 0
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
  # The search projection gave up before every row was decided; say so rather
  # than showing an overview that silently under-reports matches.
  var partial = get(session, 'search_partial', false) ? ' ~' : ''
  var position = ''
  var source_lines = get(session, 'source_lines', 0)
  if source_lines > 0 && WindowExists(get(session, 'source_winid', 0))
    var cursor_pos = getcurpos(session.source_winid)
    if len(cursor_pos) > 1
      position = printf(' · %d%%', min([100, (cursor_pos[1] * 100 + source_lines - 1) / source_lines]))
    endif
  endif
  return printf(' %s · %s%s%s%s%s%s ', label, style, pinned, position, timing, partial, state)
enddef


# A minimap taller than the file has blank rows below the drawn ones.  Pressing
# <CR> or <Space> down there used to do nothing at all; resolve to the last
# real row instead, which is the row the user is pointing just past.
def SourceTargetForRow(session: dict<any>, row_number: number): number
  if row_number < 1 || empty(session.rows)
    return 0
  endif
  var row = session.rows[Clamp(row_number, 1, len(session.rows)) - 1]
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


# Jump() and Preview() read line('.') because they are bound inside the minimap
# buffer.  A popup minimap has no such binding and is never the current window,
# so line('.') would be a *source* line: refuse rather than jump somewhere the
# user did not point at.
def CurrentEnterableSessionKey(): string
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key) || IsPopupSession(sessions[key])
    return ''
  endif
  return key
enddef


export def Jump()
  var key = CurrentEnterableSessionKey()
  if key ==# ''
    return
  endif
  var session = sessions[key]
  if empty(session.rows)
    return
  endif
  MoveSourceToRow(key, line('.'), true)
enddef


export def Preview()
  var key = CurrentEnterableSessionKey()
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


def ThumbDragEnabled(): bool
  return get(g:, 'simpleminimap_drag_thumb', 1) != 0
enddef


# A drag that starts on the viewport band drags the band -- the minimap acts as
# a scrollbar.  A drag that starts anywhere else keeps the historical
# preview-the-clicked-band behaviour.
def DragAnchorFor(session: dict<any>, row: number): dict<any>
  var band = ViewportRows(session)
  # A band spanning every row means the whole buffer is already on screen:
  # there is no scrollbar to grab, so such a drag stays a preview.
  var scrollable = band[0] > 0 && (band[1] - band[0] + 1) < len(session.rows)
  return {
    row: row,
    top_row: max([1, band[0]]),
    thumb: ThumbDragEnabled() && scrollable && row >= band[0] && row <= band[1],
    dragged: false,
  }
enddef


# Grabbing the thumb deliberately moves nothing: a press that never becomes a
# drag still resolves through MouseUp() exactly as it always did.
export def MouseDown()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  session.drag_anchor = {}
  var mouse = getmousepos()
  if get(mouse, 'winid', 0) == session.winid
      && !empty(session.rows) && get(mouse, 'line', 0) >= 1
    var anchor = DragAnchorFor(session, Clamp(mouse.line, 1, len(session.rows)))
    session.drag_anchor = anchor
    if anchor.thumb
      win_gotoid(session.winid)
      cursor(anchor.row, 1)
      return
    endif
  endif
  NavigateMouse(false)
enddef


export def MouseDrag()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var mouse = getmousepos()
  if get(mouse, 'winid', 0) != session.winid
      || empty(session.rows) || get(mouse, 'line', 0) < 1
    return
  endif
  var row = Clamp(mouse.line, 1, len(session.rows))

  var anchor = get(session, 'drag_anchor', {})
  if empty(anchor)
    # Mappings are resolved against the buffer that owns focus when the key is
    # typed, so a click that arrives while the *source* window is current never
    # reaches the minimap's buffer-local <LeftMouse> mapping: the press is
    # simply not delivered.  Anchor on the first drag event instead of losing
    # the gesture; drags stream continuously, so this row is still the one the
    # user pressed on.
    anchor = DragAnchorFor(session, row)
    session.drag_anchor = anchor
  endif
  if !anchor.thumb
    NavigateMouse(false)
    return
  endif

  # Absolute, not incremental: the target is always derived from the row the
  # gesture started on, so the thumb cannot drift away from the pointer over a
  # long drag or when a scroll is clamped at either end of the buffer.
  var target_row = Clamp(anchor.top_row + (row - anchor.row), 1, len(session.rows))
  if ScrollSourceToTop(key, session.rows[target_row - 1].start)
    anchor.dragged = true
  endif
  if WindowExists(session.winid)
    win_execute(session.winid, printf('call cursor(%d, 1)', row))
  endif
enddef


export def MouseUp()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var anchor = get(session, 'drag_anchor', {})
  session.drag_anchor = {}
  if get(anchor, 'dragged', false)
    # A thumb drag is a scroll, not a jump: leave the source cursor where the
    # scroll left it and just hand focus back.
    if WindowExists(session.source_winid)
      win_gotoid(session.source_winid)
    endif
    return
  endif
  if !NavigateMouse(true)
    win_gotoid(session.source_winid)
  endif
enddef


export def MouseJump()
  # Backward-compatible public entry point used by older mappings.
  NavigateMouse(true)
enddef


# Scroll the tracked source window so its first visible line becomes
# target_top.  winrestview({'topline': …}) cannot do this: Vim immediately
# re-clamps topline to keep the (unmoved) cursor visible, which is why wheel
# scrolling over the minimap used to do literally nothing.  <C-E>/<C-Y> is the
# scroll Vim honours, and it is what the wheel itself sends, so the cursor is
# carried along only when it would otherwise leave the window.
# Returns true when the view actually moved.
def ScrollSourceToTop(key: string, target_top: number): bool
  if !has_key(sessions, key)
    return false
  endif
  var session = sessions[key]
  if !WindowExists(session.source_winid)
    return false
  endif
  var info = WindowInfo(session.source_winid)
  var current_top = max([1, get(info, 'topline', 1)])
  var delta = target_top - current_top
  # Recorded for :SimpleMinimapDebug: the scroll a user reports as "wrong" is
  # invisible afterwards, since only the resulting topline survives.
  session.last_scroll = [current_top, target_top]
  if delta == 0
    return false
  endif
  internal_change = true
  try
    win_execute(session.source_winid,
      printf("normal! %d%s", abs(delta), delta > 0 ? "\<C-E>" : "\<C-Y>"))
  finally
    internal_change = false
  endtry
  UpdateViewport(key)
  return true
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
  var step = Clamp(get(g:, 'simpleminimap_mouse_scroll_lines', 3), 1, 50)
  var source_lines = max([1, get(source_info[0], 'linecount', 1)])
  var target_top = Clamp(get(info, 'topline', 1) + (direction * step), 1, source_lines)
  ScrollSourceToTop(key, target_top)
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
      var session_tab = SessionTab(session)
      var replacement = session_tab <= 0 ? 0 : FindSourceWindow(session_tab)
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
      UpdateOverlays(key)
      UpdateSearch(key)
    endif
  endfor
enddef


# Overlay sources that change on a command rather than on idle time -- the
# quickfix and location lists.  Waiting for the next CursorHold would leave the
# minimap showing the results of the previous :grep for up to 'updatetime'.
export def OnOverlaysChanged()
  if internal_change
    return
  endif
  for key in keys(sessions)
    UpdateOverlays(key)
  endfor
enddef


export def OnWinScrolled(winid: number)
  for [key, session] in items(sessions)
    if get(session, 'source_winid', 0) == winid
      RepositionSurface(key)
      UpdateViewport(key)
    elseif get(session, 'winid', 0) == winid
      Schedule(key)
    endif
  endfor
enddef


export def OnResized()
  for key in keys(sessions)
    RepositionSurface(key)
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
      var session_tab = SessionTab(session)
      var replacement = session_tab <= 0 ? 0 : FindSourceWindow(session_tab)
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
  ReleaseBufferListener(bufnr)
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
      var session_tab = SessionTab(session)
      var replacement = session_tab <= 0 ? 0 : FindSourceWindow(session_tab)
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


# Every g: option the plugin reads.  A misspelled option name is otherwise
# silently ignored for ever, which is the single most confusing way for a
# config to be wrong.  tests/vim_health.vim asserts this list matches the names
# plugin/simpleminimap.vim actually normalises, so it cannot drift.
const KNOWN_OPTIONS = [
  'simpleminimap_auto_close',
  'simpleminimap_auto_open',
  'simpleminimap_auto_restart',
  'simpleminimap_daemon_path',
  'simpleminimap_debounce',
  'simpleminimap_debug',
  'simpleminimap_display',
  'simpleminimap_drag_thumb',
  'simpleminimap_fill',
  'simpleminimap_ignore_filetypes',
  'simpleminimap_incremental',
  'simpleminimap_max_columns',
  'simpleminimap_mouse_scroll_lines',
  'simpleminimap_overlays',
  'simpleminimap_render_style',
  'simpleminimap_request_timeout_ms',
  'simpleminimap_sampling',
  'simpleminimap_set_default_mapping',
  'simpleminimap_shading',
  'simpleminimap_show_search',
  'simpleminimap_show_signs',
  'simpleminimap_show_statusline',
  'simpleminimap_side',
  'simpleminimap_width',
]


export def KnownOptions(): list<string>
  return copy(KNOWN_OPTIONS)
enddef


export def UnknownOptions(): list<string>
  var unknown: list<string> = []
  for name in keys(g:)
    if name =~# '^simpleminimap_' && index(KNOWN_OPTIONS, name) < 0
      unknown->add(name)
    endif
  endfor
  return sort(unknown)
enddef


# Levenshtein would be nicer, but a shared prefix or suffix catches the typos
# people actually make (widht, show_sings, requst_timeout_ms) without dragging
# a distance function into a diagnostic.
def NearestOption(name: string): string
  var best = ''
  var best_score = 0
  for candidate in KNOWN_OPTIONS
    var limit = min([len(name), len(candidate)])
    var prefix = 0
    while prefix < limit && name[prefix] ==# candidate[prefix]
      prefix += 1
    endwhile
    var suffix = 0
    while suffix < limit - prefix
        && name[len(name) - 1 - suffix] ==# candidate[len(candidate) - 1 - suffix]
      suffix += 1
    endwhile
    var score = prefix + suffix
    if score > best_score
      best_score = score
      best = candidate
    endif
  endfor
  # 'simpleminimap_' alone is 14 characters, so anything at or below that
  # matched nothing beyond the prefix every option shares.
  return best_score > 15 ? best : ''
enddef


export def Health()
  var daemon = FindDaemon()
  ProbeDaemonVersion(daemon)
  var search_supported = exists('*matchbufline')
  var checks = [
    printf('[%s] Vim version: %d', v:version >= 900 ? 'OK' : 'FAIL', v:version),
    printf('[%s] +job / +channel: %d / %d', has('job') && has('channel') ? 'OK' : 'FAIL', has('job'), has('channel')),
    printf('[%s] daemon: %s', daemon ==# '' ? 'FAIL' : 'OK', daemon ==# '' ? 'not found' : daemon),
    printf('[INFO] daemon version: %s', daemon_version ==# ''
      ? (type(daemon_version_job) == v:t_job ? 'probing…' : 'not probed yet')
      : daemon_version),
    printf('[%s] daemon protocol: %s',
      backend_protocol == 0 ? 'INFO' : (backend_protocol == PROTOCOL_VERSION ? 'OK' : 'FAIL'),
      backend_protocol == 0
        ? printf('not negotiated yet; this plugin expects v%d', PROTOCOL_VERSION)
        : (backend_protocol == PROTOCOL_VERSION
            ? printf('v%d', backend_protocol)
            : printf('daemon v%d, plugin expects v%d — run ./install.sh, then :SimpleMinimapRestart',
                backend_protocol, PROTOCOL_VERSION))),
    printf('[%s] backend: %s, ready=%d', BackendRunning() ? 'OK' : 'INFO', BackendRunning() ? job_status(backend_job) : 'stopped', backend_ready ? 1 : 0),
    printf('[INFO] backend latency: %s', backend_latency_ms >= 0.0 ? printf('%.1fms', backend_latency_ms) : 'n/a'),
    printf('[%s] search projection: %s', search_supported ? 'OK' : 'INFO', search_supported ? 'matchbufline() available' : 'disabled, needs Vim 9.1.0009+'),
    printf('[%s] density shading: %s', ShadingEnabled() ? 'OK' : 'INFO', ShadingEnabled() ? 'enabled' : (has('textprop') == 1 ? 'disabled by g:simpleminimap_shading' : 'needs +textprop')),
    printf('[INFO] sessions: %d, pending requests: %d', len(sessions), len(requests)),
    printf('[%s] incremental sampling: %s', IncrementalEnabled() ? 'OK' : 'INFO',
      IncrementalEnabled()
        ? printf('%d buffers watched, %d cached bands reused, %d resampled',
            len(sample_listeners), sample_cache_hits, sample_cache_misses)
        : (exists('*listener_add')
            ? 'disabled by g:simpleminimap_incremental; every render re-reads the whole buffer'
            : 'needs listener_add()')),
    printf('[%s] request timeout: %s', RequestTimeoutMs() > 0 ? 'OK' : 'WARN',
      RequestTimeoutMs() > 0
        ? printf('%dms, %d expired so far', RequestTimeoutMs(), backend_timeouts)
        : 'disabled by g:simpleminimap_request_timeout_ms; a wedged daemon will not be noticed'),
    printf('[%s] crash-loop breaker: %s', backend_breaker_tripped ? 'FAIL' : 'OK',
      backend_breaker_tripped
        ? printf('tripped after %d restarts in %ds (%s); run :SimpleMinimapRestart',
            backend_restart_attempts, float2nr(RESTART_WINDOW_MS / 1000.0),
            backend_breaker_reason)
        : printf('armed, %d/%d restarts used in the current window',
            backend_restart_attempts, MAX_BACKEND_RESTARTS)),
    printf('[%s] display: %s', DisplayMode() ==# get(g:, 'simpleminimap_display', 'split')
      ? 'OK' : 'WARN',
      DisplayMode() ==# get(g:, 'simpleminimap_display', 'split')
        ? DisplayMode()
        : printf("popup requested but this Vim has no +popupwin; using 'split'")),
    printf('[INFO] side/style/sampling: %s / %s / %s', get(g:, 'simpleminimap_side', 'right'), get(g:, 'simpleminimap_render_style', 'braille'), get(g:, 'simpleminimap_sampling', 'adaptive')),
  ]
  # Braille and block glyphs simply cannot be encoded in a single-byte
  # 'encoding', so the minimap renders as garbage with no other clue why.
  if &encoding !=? 'utf-8' && get(g:, 'simpleminimap_render_style', 'braille') !=# 'ascii'
    checks->add(printf(
      "[WARN] encoding is %s, not utf-8 — set g:simpleminimap_render_style = 'ascii'",
      &encoding))
  endif
  for name in UnknownOptions()
    var nearest = NearestOption(name)
    checks->add(printf('[WARN] unknown option g:%s%s', name,
      nearest ==# '' ? '' : printf(' (did you mean g:%s?)', nearest)))
  endfor
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
    backend_breaker_tripped: backend_breaker_tripped,
    backend_breaker_reason: backend_breaker_reason,
    backend_timeouts: backend_timeouts,
    backend_protocol: backend_protocol,
    daemon_version: daemon_version,
    unknown_options: UnknownOptions(),
    sample_cache: SampleCacheStats(),
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
    StopRequestTimer(session)
  endfor
  StopBackend(false)
  sessions = {}
  ReleaseUnusedListeners()
  requests = {}
  incoming = {}
  backend_restart_attempts = 0
  backend_restart_window = reltime()
  backend_breaker_tripped = false
  backend_breaker_reason = ''
  backend_timeouts = 0
  consecutive_timeouts = 0
enddef
