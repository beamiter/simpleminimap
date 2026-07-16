vim9script

const PROTOCOL_VERSION = 1
const MIN_RENDER_HEIGHT = 1
var plugin_root = fnamemodify(expand('<sfile>:p'), ':h:h')

# key (minimap window ID as string) -> session dictionary.
var sessions: dict<any> = {}
var requests: dict<string> = {}
var incoming: dict<any> = {}
var backend_job: any = v:null
var backend_path = ''
var backend_ready = false
var backend_error = ''
var next_request_id = 0
var internal_change = false


def Log(message: string)
  if get(g:, 'simpleminimap_debug', 0)
    echom '[SimpleMinimap] ' .. message
  endif
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
  return type(buftype) == v:t_string && buftype ==# ''
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


def BackendOut(_channel: channel, message: string)
  if message ==# ''
    return
  endif
  var fields = split(message, "\t", 1)
  if empty(fields)
    return
  endif

  if fields[0] ==# 'READY'
    backend_ready = len(fields) > 1 && str2nr(fields[1]) == PROTOCOL_VERSION
    if !backend_ready
      backend_error = 'backend protocol version mismatch'
    else
      backend_error = ''
    endif
    Log('backend ready: ' .. message)
    return
  endif

  if fields[0] ==# 'PONG'
    return
  endif

  if fields[0] ==# 'X'
    var id = len(fields) > 1 ? str2nr(fields[1]) : 0
    var error = len(fields) > 2 ? DecodeField(fields[2]) : 'unknown backend error'
    backend_error = error
    Log(printf('backend error for request %d: %s', id, error))
    if has_key(requests, string(id))
      var key = requests[string(id)]
      if has_key(sessions, key)
        RenderMessage(key, ['SimpleMinimap backend error', error])
      endif
      requests->remove(string(id))
    endif
    if has_key(incoming, string(id))
      incoming->remove(string(id))
    endif
    return
  endif

  if len(fields) < 2
    return
  endif
  var request_id = str2nr(fields[1])
  var request_key = string(request_id)

  if fields[0] ==# 'B'
    incoming[request_key] = {
      source_lines: len(fields) > 2 ? str2nr(fields[2]) : 0,
      expected: len(fields) > 3 ? str2nr(fields[3]) : 0,
      rows: [],
    }
  elseif fields[0] ==# 'R'
    if len(fields) < 5 || !has_key(incoming, request_key)
      return
    endif
    incoming[request_key].rows->add({
      start: str2nr(fields[2]),
      end: str2nr(fields[3]),
      text: DecodeField(fields[4]),
    })
  elseif fields[0] ==# 'E'
    if !has_key(incoming, request_key)
      return
    endif
    var response = incoming->remove(request_key)
    if !has_key(requests, request_key)
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
    if len(response.rows) != response.expected
      RenderMessage(session_key, ['SimpleMinimap incomplete response'])
      return
    endif
    ApplyRows(session_key, response.rows, response.source_lines)
  endif
enddef


def BackendErr(_channel: channel, message: string)
  if message ==# ''
    return
  endif
  backend_error = message
  Log('backend stderr: ' .. message)
enddef


def BackendExit(_job: job, status: number)
  backend_ready = false
  backend_error = printf('backend exited with status %d', status)
  requests = {}
  incoming = {}
  Log(backend_error)
  for key in keys(sessions)
    RenderMessage(key, ['SimpleMinimap backend stopped', backend_error])
  endfor
enddef


def StartBackend(): bool
  if BackendRunning()
    return true
  endif

  backend_path = FindDaemon()
  if backend_path ==# ''
    backend_ready = false
    backend_error = 'daemon not found; run install.sh (or install.ps1)'
    return false
  endif

  try
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
  SetBufferLines(session.bufnr, output)
  ClearMatches(key)
enddef


def BuildSampleGroup(bufnr: number, start_line: number, end_line: number, max_chars: number): list<string>
  var samples: list<string> = []
  var count = end_line - start_line + 1
  if count <= 4
    var line_number = start_line
    while line_number <= end_line
      var text = getbufline(bufnr, line_number)
      samples->add(empty(text) ? '' : strcharpart(text[0], 0, max_chars))
      line_number += 1
    endwhile
    while len(samples) < 4
      samples->add('')
    endwhile
    return samples
  endif

  for sample_index in range(0, 3)
    var offset = ((sample_index * 2 + 1) * count) / 8
    var line_number = min([end_line, start_line + offset])
    var text = getbufline(bufnr, line_number)
    samples->add(empty(text) ? '' : strcharpart(text[0], 0, max_chars))
  endfor
  return samples
enddef


def BuildPayload(key: string, request_id: number): string
  var session = sessions[key]
  var dimensions = WindowDimensions(session.winid)
  var width = Clamp(dimensions[0], 1, 256)
  var height = Clamp(dimensions[1], MIN_RENDER_HEIGHT, 2000)
  var source_info = getbufinfo(session.source_bufnr)
  if empty(source_info)
    return ''
  endif
  var source_lines = max([1, get(source_info[0], 'linecount', 1)])
  var row_count = min([height, max([1, (source_lines + 3) / 4])])
  var max_columns = Clamp(get(g:, 'simpleminimap_max_columns', 120), 20, 1000)
  var tabstop = Clamp(getbufvar(session.source_bufnr, '&tabstop'), 1, 64)
  var style = get(g:, 'simpleminimap_render_style', 'braille')
  if index(['braille', 'blocks', 'ascii'], style) < 0
    style = 'braille'
  endif

  var parts: list<string> = []
  parts->add(printf("B\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d",
    request_id, width, height, max_columns, tabstop, style, source_lines, row_count, PROTOCOL_VERSION))
  var max_chars = max_columns
  for row_index in range(0, row_count - 1)
    var start_zero = (row_index * source_lines) / row_count
    var end_zero = (((row_index + 1) * source_lines) / row_count) - 1
    var start_line = start_zero + 1
    var end_line = max([start_line, end_zero + 1])
    var samples = BuildSampleGroup(session.source_bufnr, start_line, end_line, max_chars)
    parts->add(printf("G\t%d\t%d\t%d\t%s\t%s\t%s\t%s",
      request_id, start_line, end_line,
      EncodeField(samples[0]), EncodeField(samples[1]), EncodeField(samples[2]), EncodeField(samples[3])))
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

  next_request_id += 1
  if next_request_id <= 0
    next_request_id = 1
  endif
  var request_id = next_request_id
  session.request_id = request_id
  session.source_bufnr = WindowInfo(session.source_winid).bufnr
  var payload = BuildPayload(key, request_id)
  if payload ==# ''
    RenderMessage(key, ['SimpleMinimap', 'source buffer unavailable'])
    return
  endif

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


def Schedule(key: string, delay: number = -1)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
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


def ClearMatches(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if !WindowExists(session.winid)
    return
  endif
  for field in ['viewport_match', 'cursor_match']
    var match_id = get(session, field, -1)
    if match_id > 0
      try
        matchdelete(match_id, session.winid)
      catch
      endtry
      session[field] = -1
    endif
  endfor
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

  ClearMatches(key)
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
  SetBufferLines(session.bufnr, output)
  UpdateViewport(key)
enddef


def ConfigureMinimapWindow(winid: number, bufnr: number)
  win_execute(winid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted')
  win_execute(winid, 'setlocal nowrap nonumber norelativenumber nocursorcolumn nocursorline')
  win_execute(winid, 'setlocal signcolumn=no foldcolumn=0 nofoldenable nolist')
  win_execute(winid, 'setlocal scrolloff=0 sidescrolloff=0 winfixwidth')
  win_execute(winid, 'setlocal filetype=simpleminimap wincolor=SimpleMinimapNormal')
  if get(g:, 'simpleminimap_show_statusline', 1)
    setwinvar(winid, '&statusline', '%#SimpleMinimapTitle# SimpleMinimap ')
  else
    setwinvar(winid, '&statusline', '')
  endif
  setbufvar(bufnr, '&modifiable', 0)
  setbufvar(bufnr, '&modified', 0)

  win_execute(winid, 'nnoremap <silent> <buffer> q <Cmd>SimpleMinimapClose<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> r <Cmd>SimpleMinimapRefresh<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <CR> <Cmd>call simpleminimap#Jump()<CR>')
  win_execute(winid, 'nnoremap <silent> <buffer> <LeftMouse> <LeftMouse><Cmd>call simpleminimap#MouseJump()<CR>')
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

  internal_change = true
  try
    botright vertical new
    execute 'vertical resize ' .. get(g:, 'simpleminimap_width', 18)
    var minimap_winid = win_getid()
    var minimap_bufnr = bufnr()
    var key = string(minimap_winid)
    sessions[key] = {
      winid: minimap_winid,
      bufnr: minimap_bufnr,
      source_winid: source_winid,
      source_bufnr: WindowInfo(source_winid).bufnr,
      rows: [],
      source_lines: 0,
      request_id: 0,
      timer: 0,
      viewport_match: -1,
      cursor_match: -1,
    }
    ConfigureMinimapWindow(minimap_winid, minimap_bufnr)
    SetBufferLines(minimap_bufnr, ['SimpleMinimap starting…'])
    win_gotoid(source_winid)
    Schedule(key, 0)
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
  highlight default link SimpleMinimapTitle Title
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


export def Refresh()
  var key = CurrentSessionKey()
  if key !=# ''
    Schedule(key, 0)
  endif
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
  var row_number = line('.')
  if row_number < 1 || row_number > len(session.rows)
    return
  endif
  var row = session.rows[row_number - 1]
  var target = row.start + ((row.end - row.start) / 2)
  if win_gotoid(session.source_winid)
    cursor(target, 1)
    normal! zz
    UpdateViewport(key)
  endif
enddef


export def MouseJump()
  var mouse = getmousepos()
  var key = CurrentSessionKey()
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if get(mouse, 'winid', 0) != session.winid
    return
  endif
  var row_number = get(mouse, 'line', 0)
  if row_number < 1 || row_number > len(session.rows)
    return
  endif
  win_gotoid(session.winid)
  cursor(row_number, 1)
  Jump()
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
  if current_winid == session.winid || !IsEligibleSourceWindow(current_winid)
    return
  endif
  var info = WindowInfo(current_winid)
  var changed = session.source_winid != current_winid || session.source_bufnr != info.bufnr
  session.source_winid = current_winid
  session.source_bufnr = info.bufnr
  if changed
    Schedule(key, 0)
  else
    UpdateViewport(key)
  endif
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
  var key = CurrentSessionKey()
  if key !=# ''
    Schedule(key)
  endif
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
      var tab_info = WindowInfo(session.winid)
      var replacement = empty(tab_info) ? 0 : FindSourceWindow(tab_info.tabnr)
      if replacement > 0
        session.source_winid = replacement
        session.source_bufnr = WindowInfo(replacement).bufnr
        Schedule(key, 0)
      elseif get(g:, 'simpleminimap_auto_close', 0)
        CloseSession(key)
      else
        RenderMessage(key, ['SimpleMinimap', 'no editable window'])
      endif
    endif
  endfor
enddef


export def OnBufferWipeout(bufnr: number)
  for [key, session] in items(sessions)
    if get(session, 'bufnr', -1) == bufnr
      DropSession(key)
      return
    endif
    if get(session, 'source_bufnr', -1) == bufnr
      var tab_info = WindowInfo(session.winid)
      var replacement = empty(tab_info) ? 0 : FindSourceWindow(tab_info.tabnr)
      if replacement > 0
        session.source_winid = replacement
        session.source_bufnr = WindowInfo(replacement).bufnr
        Schedule(key, 0)
      endif
    endif
  endfor
enddef


export def Health()
  var checks = [
    printf('Vim version: %d', v:version),
    printf('+job: %d', has('job')),
    printf('+channel: %d', has('channel')),
    printf('+textprop: %d', has('textprop')),
    printf('daemon: %s', FindDaemon() ==# '' ? 'not found' : FindDaemon()),
    printf('backend status: %s', BackendRunning() ? job_status(backend_job) : 'stopped'),
    printf('protocol ready: %d', backend_ready),
  ]
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
  sessions = {}
  requests = {}
  incoming = {}
  if BackendRunning()
    try
      job_stop(backend_job)
    catch
    endtry
  endif
  backend_ready = false
enddef
