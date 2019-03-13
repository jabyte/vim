let s:save_cpo = &cpo
set cpo&vim

function! s:_vital_loaded(V) abort
  let s:V = a:V
endfunction

function! s:_vital_depends() abort
  return ['Web.URI.HTTP', 'Web.URI.HTTPS']
endfunction

" NOTE: See s:DefaultPatternSet about the reason
" why s:DefaultPatternSet is not deepcopy()ed here.
function! s:new(uri, ...) abort
  let NothrowValue = get(a:000, 0, s:NONE)
  let pattern_set  = get(a:000, 1, s:DefaultPatternSet)
  return s:_uri_new_sandbox(
  \   a:uri, 0, pattern_set, 0, NothrowValue)
endfunction

" NOTE: See s:DefaultPatternSet about the reason
" why s:DefaultPatternSet is not deepcopy()ed here.
function! s:new_from_uri_like_string(str, ...) abort
  let NothrowValue = get(a:000, 0, s:NONE)
  let pattern_set  = get(a:000, 1, s:DefaultPatternSet)
  " Prepend http if no scheme.
  if a:str !~# '^' . pattern_set.get('scheme') . '://'
    let str = 'http://' . a:str
  else
    let str = a:str
  endif

  return s:_uri_new_sandbox(
  \   str, 0, pattern_set, 0, NothrowValue)
endfunction

" NOTE: See s:DefaultPatternSet about the reason
" why s:DefaultPatternSet is not deepcopy()ed here.
function! s:new_from_seq_string(uri, ...) abort
  let NothrowValue = get(a:000, 0, s:NONE)
  let pattern_set  = get(a:000, 1, s:DefaultPatternSet)
  return s:_uri_new_sandbox(
  \   a:uri, 1, pattern_set, 1, NothrowValue)
endfunction

function! s:is_uri(str) abort
  let ERROR = []
  return s:new(a:str, ERROR) isnot ERROR
endfunction

function! s:like_uri(str) abort
  let ERROR = []
  return s:new_from_uri_like_string(a:str, ERROR) isnot ERROR
endfunction

function! s:encode(str, ...) abort
  let encoding = a:0 ? a:1 : 'utf-8'
  if encoding ==# ''
    let str = a:str
  else
    let str = iconv(a:str, &encoding, encoding)
  endif

  let result = ''
  for i in range(len(str))
    if str[i] =~# '^[a-zA-Z0-9_.~-]$'
      let result .= str[i]
    else
      let result .= printf('%%%02X', char2nr(str[i]))
    endif
  endfor
  return result
endfunction

function! s:decode(str, ...) abort
  let result = substitute(a:str, '%\(\x\x\)',
  \   '\=printf("%c", str2nr(submatch(1), 16))', 'g')

  let encoding = a:0 ? a:1 : 'utf-8'
  if encoding ==# ''
    return result
  endif
  return iconv(result, encoding, &encoding)
endfunction


let s:NONE = []

function! s:_uri_new_sandbox(uri, ignore_rest, pattern_set, retall, NothrowValue) abort
  try
    let results = call('s:_uri_new', [a:uri, a:ignore_rest, a:pattern_set])
    return a:retall ? results : results[0]
  catch
    if a:NothrowValue isnot s:NONE && s:_is_own_exception(v:exception)
      return a:NothrowValue
    else
      let ex = substitute(v:exception, '^Vim([^()]\+):', '', '')
      throw 'vital: Web.URI: ' . ex . ' @ ' . v:throwpoint
      \   . ' (original URI: ' . a:uri . ')'
    endif
  endtry
endfunction

function! s:_is_own_exception(str) abort
  return a:str =~# '^vital: Web.URI: uri parse error\%(([^)]\+)\)\?:'
endfunction


" ================ Parsing Functions ================

" @return instance of s:URI .
"
" TODO: Support punycode
"
" Quoted the outline of RFC3986 here.
" RFC3986: http://tools.ietf.org/html/rfc3986
"
" URI = scheme ":" hier-part [ "?" query ] [ "#" fragment ]
" authority = [ userinfo "@" ] host [ ":" port ]
function! s:_parse_uri(str, ignore_rest, pattern_set) abort
  let rest = a:str

  " Ignore leading/trailing whitespaces.
  let rest = substitute(rest, '^\s\+', '', '')
  let rest = substitute(rest, '\s\+$', '', '')

  " scheme
  let [scheme, rest] = s:_eat_scheme(rest, a:pattern_set)

  " hier-part
  let [hier_part, rest] = s:_eat_hier_part(rest, a:pattern_set)

  " query
  if rest[0] ==# '?'
    let [query, rest] = s:_eat_query(rest[1:], a:pattern_set)
  else
    let query = ''
  endif

  " fragment
  if rest[0] ==# '#'
    let [fragment, rest] = s:_eat_fragment(rest[1:], a:pattern_set)
  else
    let fragment = ''
  endif

  if !a:ignore_rest && rest !=# ''
    throw 'vital: Web.URI: uri parse error: unnecessary string at the end.'
  endif

  let obj = deepcopy(s:URI)
  let obj.__scheme = scheme
  let obj.__userinfo = hier_part.userinfo
  let obj.__host = hier_part.host
  let obj.__port = hier_part.port
  let obj.__path = hier_part.path
  " NOTE: obj.__query must not have "?" as prefix.
  let obj.__query = substitute(query, '^?', '', '')
  " NOTE: obj.__fragment must not have "#" as prefix.
  let obj.__fragment = substitute(fragment, '^#', '', '')
  let obj.__pattern_set = a:pattern_set
  let obj.__handler = s:_get_handler_module(scheme, obj)
  return [obj, rest]
endfunction

function! s:_get_handler_module(scheme, uriobj) abort
  if a:scheme ==# ''
    return {}
  endif
  let name = 'Web.URI.' . toupper(a:scheme)
  if !s:V.exists(name)
    return {}
  endif
  return s:V.import(name)
endfunction

function! s:_eat_em(str, pat, ...) abort
  let pat = a:pat.'\C'
  let m = matchlist(a:str, pat)
  if empty(m)
    let prefix = printf('uri parse error%s: ', (a:0 ? '('.a:1.')' : ''))
    let msg = printf("can't parse '%s' with '%s'.", a:str, pat)
    throw 'vital: Web.URI: ' . prefix . msg
  endif
  let rest = strpart(a:str, strlen(m[0]))
  return [m[0], rest]
endfunction

" hier-part = "//" authority path-abempty
"           / path-absolute
"           / path-noscheme
"           / path-rootless
"           / path-empty
function! s:_eat_hier_part(rest, pattern_set) abort
  let rest = a:rest
  if rest =~# '^://'
    " authority
    let rest = rest[3:]
    let [authority, rest] = s:_eat_authority(rest, a:pattern_set)
    let userinfo = authority.userinfo
    let host = authority.host
    let port = authority.port
    " path
    let [path, rest] = s:_eat_path_abempty(rest, a:pattern_set)
  elseif rest =~# '^:'
    let rest = rest[1:]
    let userinfo = ''
    let host = ''
    let port = ''
    " path
    if rest =~# '^/[^/]'    " begins with '/' but not '//'
      let [path, rest] = s:_eat_path_absolute(rest, a:pattern_set)
    elseif rest =~# '^[^:]'    " begins with a non-colon segment
      let [path, rest] = s:_eat_path_noscheme(rest, a:pattern_set)
    elseif rest =~# a:pattern_set.segment_nz()    " begins with a segment
      let [path, rest] = s:_eat_path_rootless(rest, a:pattern_set)
    elseif rest ==# '' || rest =~# '^[?#]'    " zero characters
      let path = ''
    else
      throw printf("vital: Web.URI: uri parse error(hier-part): can't parse '%s'.", rest)
    endif
  else
    throw printf("vital: Web.URI: uri parse error(hier-part): can't parse '%s'.", rest)
  endif
  return [{
  \ 'userinfo': userinfo,
  \ 'host': host,
  \ 'port': port,
  \ 'path': path,
  \}, rest]
endfunction

function! s:_eat_authority(str, pattern_set) abort
  let rest = a:str
  " authority(userinfo)
  try
    let oldrest = rest
    let [userinfo, rest] = s:_eat_userinfo(rest, a:pattern_set)
    let rest = s:_eat_em(rest, '^@')[1]
  catch
    let rest = oldrest
    let userinfo = ''
  endtry
  " authority(host)
  let [host, rest] = s:_eat_host(rest, a:pattern_set)
  " authority(port)
  if rest[0] ==# ':'
    let [port, rest] = s:_eat_port(rest[1:], a:pattern_set)
  else
    let port = ''
  endif
  return [{
  \ 'userinfo': userinfo,
  \ 'host': host,
  \ 'port': port,
  \}, rest]
endfunction

" NOTE: More s:_eat_*() functions are defined by s:_create_eat_functions().
" =============== Parsing Functions ===============


" ===================== s:URI =====================

function! s:_uri_new(str, ignore_rest, pattern_set) abort
  let [obj, rest] = s:_parse_uri(a:str, a:ignore_rest, a:pattern_set)
  if a:ignore_rest
    let original_url = a:str[: len(a:str)-len(rest)-1]
    return [obj, original_url, rest]
  else
    return [obj, a:str, '']
  endif
endfunction

function! s:_uri_scheme(...) dict abort
  if a:0
    if self.is_scheme(a:1)
      let self.__scheme = a:1
      return self
    else
      throw 'vital: Web.URI: scheme(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__scheme
endfunction

function! s:_uri_userinfo(...) dict abort
  if a:0
    if self.is_userinfo(a:1)
      let self.__userinfo = a:1
      return self
    else
      throw 'vital: Web.URI: userinfo(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__userinfo
endfunction

function! s:_uri_host(...) dict abort
  if a:0
    if self.is_host(a:1)
      let self.__host = a:1
      return self
    else
      throw 'vital: Web.URI: host(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__host
endfunction

function! s:_uri_port(...) dict abort
  if a:0
    if type(a:1) ==# type(0)
      let self.__port = '' . a:1
      return self
    elseif type(a:1) ==# type('') && self.is_port(a:1)
      let self.__port = a:1
      return self
    else
      throw 'vital: Web.URI: port(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__port
endfunction

function! s:_uri_path(...) dict abort
  if a:0
    if self.is_path(a:1)
      let self.__path = a:1
      return self
    else
      throw 'vital: Web.URI: path(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__path
endfunction

function! s:_uri_authority(...) dict abort
  if a:0
    " TODO
    throw 'vital: Web.URI: uri.authority(value) does not support yet.'
  endif
  return
  \   (self.__userinfo !=# '' ? self.__userinfo . '@' : '')
  \   . self.__host
  \   . (self.__port !=# '' ? ':' . self.__port : '')
endfunction

function! s:_uri_opaque(...) dict abort
  if a:0
    " TODO
    throw 'vital: Web.URI: uri.opaque(value) does not support yet.'
  endif
  return printf('//%s%s',
  \           self.authority(),
  \           self.__path)
endfunction

function! s:_uri_query(...) dict abort
  if a:0
    " NOTE: self.__query must not have "?" as prefix.
    let query = substitute(a:1, '^?', '', '')
    if self.is_query(query)
      let self.__query = query
      return self
    else
      throw 'vital: Web.URI: query(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__query
endfunction

function! s:_uri_fragment(...) dict abort
  if a:0
    " NOTE: self.__fragment must not have "#" as prefix.
    let fragment = substitute(a:1, '^#', '', '')
    if self.is_fragment(fragment)
      let self.__fragment = fragment
      return self
    else
      throw 'vital: Web.URI: fragment(): '
      \   . 'invalid argument (' . string(a:1) . ')'
    endif
  endif
  return self.__fragment
endfunction

function! s:_uri_canonicalize() dict abort
  call s:_call_handler_method(self, 'canonicalize', [])
  return self
endfunction

function! s:_uri_default_port() dict abort
  return s:_call_handler_method(self, 'default_port', [])
endfunction

function! s:_call_handler_method(this, name, args) abort
  if empty(a:this.__handler)
    throw 'vital: Web.URI: ' . a:name . '(): '
    \   . "Handler was not found for scheme '" . a:this.__scheme . "'."
  endif
  return call(a:this.__handler[a:name], [a:this] + a:args)
endfunction

function! s:_uri_clone() dict abort
  return deepcopy(self)
endfunction

function! s:_uri_relative(relstr) dict abort
  call self.canonicalize()
  let relobj = s:_parse_relative_ref(a:relstr, self.__pattern_set)
  call s:_resolve_relative(self, relobj)
  return self
endfunction

" @seealso s:_parse_uri()
"
" URI-reference = URI / relative-ref
" relative-ref = relative-part [ "?" query ] [ "#" fragment ]
function! s:_parse_relative_ref(relstr, pattern_set) abort
  " relative-part
  let [relpart, rest] = s:_parse_relative_part(a:relstr, a:pattern_set)
  " query
  if rest[0] ==# '?'
    let [query, rest] = s:_eat_query(rest[1:], a:pattern_set)
  else
    let query = ''
  endif
  " fragment
  if rest[0] ==# '#'
    let [fragment, rest] = s:_eat_fragment(rest[1:], a:pattern_set)
  else
    let fragment = ''
  endif
  " no trailing string allowed.
  if rest !=# ''
    throw 'vital: Web.URI: uri parse error(relative-ref): unnecessary string at the end.'
  endif

  let obj = deepcopy(s:URI)
  let obj.__pattern_set = s:clone_pattern_set(a:pattern_set)
  let obj.__scheme = ''
  let obj.__userinfo = relpart.userinfo
  let obj.__host = relpart.host
  let obj.__port = relpart.port
  let obj.__path = relpart.path
  " NOTE: obj.__query must not have "?" as prefix.
  let obj.__query = substitute(query, '^?', '', '')
  " NOTE: obj.__fragment must not have "#" as prefix.
  let obj.__fragment = substitute(fragment, '^#', '', '')
  return obj
endfunction

" @seealso s:_eat_hier_part()
"
" relative-part = "//" authority path-abempty
"               / path-absolute
"               / path-noscheme
"               / path-empty
function! s:_parse_relative_part(rel_uri, pattern_set) abort
  let rest = a:rel_uri
  if rest =~# '^//'
    " authority
    let rest = rest[2:]
    let [authority, rest] = s:_eat_authority(rest, a:pattern_set)
    let userinfo = authority.userinfo
    let host = authority.host
    let port = authority.port
    " path
    let [path, rest] = s:_eat_path_abempty(rest, a:pattern_set)
  else
    let userinfo = ''
    let host = ''
    let port = ''
    " path
    if rest =~# '^/[^/]'    " begins with '/' but not '//'
      let [path, rest] = s:_eat_path_absolute(rest, a:pattern_set)
    elseif rest =~# '^[^:]'    " begins with a non-colon segment
      let [path, rest] = s:_eat_path_noscheme(rest, a:pattern_set)
    elseif rest ==# '' || rest =~# '^[?#]'    " zero characters
      let path = ''
    else
      throw printf("vital: Web.URI: uri parse error(relative-part): can't parse '%s'.", rest)
    endif
  endif
  return [{
  \ 'userinfo': userinfo,
  \ 'host': host,
  \ 'port': port,
  \ 'path': path,
  \}, rest]
endfunction

" https://tools.ietf.org/html/rfc3986#section-5.2.2
function! s:_resolve_relative(obj, relobj) abort
  if a:relobj.__scheme !=# ''
    let a:obj.__scheme   = a:relobj.__scheme
    let a:obj.__userinfo = a:relobj.__userinfo
    let a:obj.__host     = a:relobj.__host
    let a:obj.__port     = a:relobj.__port
    let a:obj.__path     = s:_remove_dot_segments(a:relobj.__path)
    let a:obj.__query    = a:relobj.__query
  else
    if a:relobj.authority() !=# ''
      let a:obj.__userinfo = a:relobj.__userinfo
      let a:obj.__host     = a:relobj.__host
      let a:obj.__port     = a:relobj.__port
      let a:obj.__path     = a:relobj.__path
      let a:obj.__query    = a:relobj.__query
    else
      if a:relobj.__path ==# ''
        if a:relobj.__query !=# ''
          let a:obj.__query = a:relobj.__query
        endif
      else
        if a:relobj.__path[0] ==# '/'
          let a:obj.__path = s:_remove_dot_segments(a:relobj.__path)
        else
          let a:obj.__path = s:_merge_paths(a:obj, a:relobj)
          let a:obj.__path = s:_remove_dot_segments(a:obj.__path)
        endif
        let a:obj.__query = a:relobj.__query
      endif
    endif
  endif
  let a:obj.__fragment = a:relobj.__fragment
endfunction

" Merge base URI and relative URI.
"
" 5.2.3. Merge Paths
" https://tools.ietf.org/html/rfc3986#section-5.2.3
function! s:_merge_paths(baseobj, relobj) abort
  if a:baseobj.authority() !=# '' && a:baseobj.__path ==# ''
    return a:relobj.__path
  else
    return substitute(a:baseobj.__path, '/\zs[^/]\+$', '', '')
    \    . a:relobj.__path
  endif
endfunction

" Remove '.' or '..' in a:path.
" Trailing '.' or '..' leaves '/' at the end.
" e.g.:
"   base: http://example.com/a/b/c
"   rel: d/.
"   result: http://example.com/a/b/d/
"
" 5.2.4. Remove Dot Segments
" https://tools.ietf.org/html/rfc3986#section-5.2.4
function! s:_remove_dot_segments(path) abort
  " Get rid of continuous '/'.
  " May exist empty string because of starting/trailing '/'.
  let paths = split(a:path, '/\+', 1)
  let i = 0
  while i < len(paths)
    if paths[i] ==# '.'
      call remove(paths, i)
      if i >=# len(paths)
        call add(paths, '')
      endif
    elseif paths[i] ==# '..'
      call remove(paths, i)
      " except starting '/..' or '..'
      if !empty(paths) && i > 0 && paths[i-1] !=# ''
        call remove(paths, i-1)
        let i -= 1
      endif
      if i >=# len(paths)
        call add(paths, '')
      endif
    else
      let i += 1
    endif
  endwhile
  return join(paths, '/')
endfunction

function! s:_uri_to_iri(...) dict abort
  " Same as uri.to_string(), but do unescape for self.__path.
  return printf(
  \   '%s://%s%s%s%s',
  \   self.__scheme,
  \   self.authority(),
  \   call('s:decode', [self.__path] + (a:0 ? [a:1] : [])),
  \   (self.__query !=# '' ? '?' . self.__query : ''),
  \   (self.__fragment !=# '' ? '#' . self.__fragment : ''),
  \)
endfunction

function! s:_uri_to_string() dict abort
  return printf(
  \   '%s://%s%s%s%s',
  \   self.__scheme,
  \   self.authority(),
  \   self.__path,
  \   (self.__query !=# '' ? '?' . self.__query : ''),
  \   (self.__fragment !=# '' ? '#' . self.__fragment : ''),
  \)
endfunction


let s:FUNCTION_DESCS = [
\ 'scheme', 'userinfo', 'host',
\ 'port', 'path', 'path_abempty',
\ 'path_absolute', 'path_noscheme',
\ 'path_rootless',
\ 'query', 'fragment'
\]

" Create s:_eat_*() functions.
function! s:_create_eat_functions() abort
  for where in s:FUNCTION_DESCS
    execute join([
    \ 'function! s:_eat_'.where.'(str, pattern_set) abort',
    \   'return s:_eat_em(a:str, "^" . a:pattern_set.get('.string(where).'), '.string(where).')',
    \ 'endfunction',
    \], "\n")
  endfor
endfunction
call s:_create_eat_functions()

" Create s:_uri_is_*() functions.
function! s:_has_error(func, args) abort
  try
    call call(a:func, a:args)
    return 0
  catch
    return 1
  endtry
endfunction
function! s:_create_check_functions() abort
  for where in s:FUNCTION_DESCS
    execute join([
    \ 'function! s:_uri_is_'.where.'(str) dict abort',
    \   'return !s:_has_error("s:_eat_'.where.'", [a:str, self.__pattern_set])',
    \ 'endfunction',
    \], "\n")
  endfor
endfunction
call s:_create_check_functions()


function! s:_local_func(name) abort
  let sid = matchstr(expand('<sfile>'), '<SNR>\zs\d\+\ze__local_func$')
  return function('<SNR>' . sid . '_' . a:name)
endfunction

let s:URI = {
\ '__scheme': '',
\ '__userinfo': '',
\ '__host': '',
\ '__port': '',
\ '__path': '',
\ '__query': '',
\ '__fragment': '',
\
\ '__pattern_set': {},
\
\ 'scheme': s:_local_func('_uri_scheme'),
\ 'userinfo': s:_local_func('_uri_userinfo'),
\ 'host': s:_local_func('_uri_host'),
\ 'port': s:_local_func('_uri_port'),
\ 'path': s:_local_func('_uri_path'),
\ 'authority': s:_local_func('_uri_authority'),
\ 'opaque': s:_local_func('_uri_opaque'),
\ 'query': s:_local_func('_uri_query'),
\ 'fragment': s:_local_func('_uri_fragment'),
\
\ 'clone': s:_local_func('_uri_clone'),
\ 'relative': s:_local_func('_uri_relative'),
\ 'canonicalize': s:_local_func('_uri_canonicalize'),
\ 'default_port': s:_local_func('_uri_default_port'),
\
\ 'to_iri': s:_local_func('_uri_to_iri'),
\ 'to_string': s:_local_func('_uri_to_string'),
\
\ 'is_scheme': s:_local_func('_uri_is_scheme'),
\ 'is_userinfo': s:_local_func('_uri_is_userinfo'),
\ 'is_host': s:_local_func('_uri_is_host'),
\ 'is_port': s:_local_func('_uri_is_port'),
\ 'is_path': s:_local_func('_uri_is_path'),
\ 'is_query': s:_local_func('_uri_is_query'),
\ 'is_fragment': s:_local_func('_uri_is_fragment'),
\}

" ===================== s:URI =====================


" ================= s:DefaultPatternSet ==================
" s:DefaultPatternSet: Default patterns for URI syntax
"
" @seealso http://tools.ietf.org/html/rfc3986

" s:new*() methods do not create new copy of s:DefaultPatternSet
" Thus it shares this instance also cache.
" But it is no problem because of the following reasons.
" 1. Each component's return value doesn't change
"    unless it is overridden by a user. but...
" 2. s:DefaultPatternSet can't be accessed by a user.
let s:DefaultPatternSet = {'_cache': {}}

function! s:new_default_pattern_set() abort
  return s:clone_pattern_set(s:DefaultPatternSet)
endfunction

function! s:clone_pattern_set(pattern_set) abort
  let pattern_set = deepcopy(a:pattern_set)
  let pattern_set._cache = {}
  return pattern_set
endfunction

" Memoize
function! s:DefaultPatternSet.get(component, ...) abort
  if has_key(self._cache, a:component)
    return self._cache[a:component]
  endif
  let ret = call(self[a:component], a:000, self)
  let self._cache[a:component] = ret
  return ret
endfunction

" unreserved    = ALPHA / DIGIT / "." / "_" / "~" / "-"
function! s:DefaultPatternSet.unreserved() abort
  return '[[:alpha:]0-9._~-]'
endfunction
" pct-encoded   = "%" HEXDIG HEXDIG
function! s:DefaultPatternSet.pct_encoded() abort
  return '%\x\x'
endfunction
" sub-delims    = "!" / "$" / "&" / "'" / "(" / ")"
"               / "*" / "+" / "," / ";" / "="
function! s:DefaultPatternSet.sub_delims() abort
  return '[!$&''()*+,;=]'
endfunction
" dec-octet   = DIGIT                 ; 0-9
"             / %x31-39 DIGIT         ; 10-99
"             / "1" 2DIGIT            ; 100-199
"             / "2" %x30-34 DIGIT     ; 200-249
"             / "25" %x30-35          ; 250-255
function! s:DefaultPatternSet.dec_octet() abort
  return '\%(1[0-9][0-9]\|2[0-4][0-9]\|25[0-5]\|[1-9][0-9]\|[0-9]\)'
endfunction
" IPv4address = dec-octet "." dec-octet "." dec-octet "." dec-octet
function! s:DefaultPatternSet.ipv4address() abort
  return self.dec_octet() . '\.' . self.dec_octet()
  \    . '\.' . self.dec_octet() . '\.' . self.dec_octet()
endfunction
" IPv6address =                            6( h16 ":" ) ls32
"             /                       "::" 5( h16 ":" ) ls32
"             / [               h16 ] "::" 4( h16 ":" ) ls32
"             / [ *1( h16 ":" ) h16 ] "::" 3( h16 ":" ) ls32
"             / [ *2( h16 ":" ) h16 ] "::" 2( h16 ":" ) ls32
"             / [ *3( h16 ":" ) h16 ] "::"    h16 ":"   ls32
"             / [ *4( h16 ":" ) h16 ] "::"              ls32
"             / [ *5( h16 ":" ) h16 ] "::"              h16
"             / [ *6( h16 ":" ) h16 ] "::"
"
" NOTE: Using repeat() in some parts because
" can't use /\{ at most 10 in whole regexp.
" https://github.com/vim/vim/blob/cde885473099296c4837de261833f48b24caf87c/src/regexp.c#L1884
function! s:DefaultPatternSet.ipv6address() abort
  return '\%(' . join([
  \ (repeat('\%(' . self.h16() . ':\)', 6) . self.ls32()),
  \ ('::' . repeat('\%(' . self.h16() . ':\)', 5) . self.ls32()),
  \ ('\%(' . self.h16() . '\)\?::'
  \   . repeat('\%(' . self.h16() . ':\)', 4) . self.ls32()),
  \ ('\%(\%(' . self.h16() . ':\)\?'    . self.h16() . '\)\?::'
  \   . repeat('\%(' . self.h16() . ':\)', 3) . self.ls32()),
  \ ('\%(\%(' . self.h16() . ':\)\{,2}' . self.h16() . '\)\?::'
  \   . repeat('\%(' . self.h16() . ':\)', 2) . self.ls32()),
  \ ('\%(\%(' . self.h16() . ':\)\{,3}' . self.h16() . '\)\?::'
  \   . self.h16() . ':' . self.ls32()),
  \ ('\%(\%(' . self.h16() . ':\)\{,4}' . self.h16() . '\)\?::' . self.ls32()),
  \ ('\%(\%(' . self.h16() . ':\)\{,5}' . self.h16() . '\)\?::' . self.h16()),
  \ ('\%(\%(' . self.h16() . ':\)\{,6}' . self.h16() . '\)\?::')
  \], '\|') . '\)'
endfunction
" h16 = 1*4HEXDIG
"     ; 16 bits of address represented in hexadecimal
function! s:DefaultPatternSet.h16() abort
  return '\x\{1,4}'
endfunction
" ls32 = ( h16 ":" h16 ) / IPv4address
"      ; least-significant 32 bits of address
function! s:DefaultPatternSet.ls32() abort
  return '\%(' . self.h16() . ':' . self.h16()
  \    . '\|' . self.ipv4address() . '\)'
endfunction
" IPvFuture = "v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" )
function! s:DefaultPatternSet.ipv_future() abort
  return 'v\x\+\.'
  \    . '\%(' . join([self.unreserved(),
  \                    self.sub_delims(), ':'], '\|') . '\)\+'
endfunction
" IP-Literal = "[" ( IPv6address / IPvFuture  ) "]"
function! s:DefaultPatternSet.ip_literal() abort
  return '\[\%(' . self.ipv6address() . '\|' . self.ipv_future() . '\)\]'
endfunction
" reg-name = *( unreserved / pct-encoded / sub-delims )
function! s:DefaultPatternSet.reg_name() abort
  return '\%(' . join([self.unreserved(), self.pct_encoded(),
  \                    self.sub_delims()], '\|') . '\)*'
endfunction
" pchar = unreserved / pct-encoded / sub-delims / ":" / "@"
function! s:DefaultPatternSet.pchar() abort
  return '\%(' . join([self.unreserved(), self.pct_encoded(),
  \                    self.sub_delims(), ':', '@'], '\|') . '\)'
endfunction
" segment = *pchar
function! s:DefaultPatternSet.segment() abort
  return self.pchar() . '*'
endfunction
" segment-nz = 1*pchar
function! s:DefaultPatternSet.segment_nz() abort
  return self.pchar() . '\+'
endfunction
" segment-nz-nc = 1*( unreserved / pct-encoded / sub-delims / "@" )
"               ; non-zero-length segment without any colon ":"
function! s:DefaultPatternSet.segment_nz_nc() abort
  return '\%(' . join([self.unreserved(), self.pct_encoded(),
  \                    self.sub_delims(), '@'], '\|') . '\)\+'
endfunction
" path-abempty = *( "/" segment )
function! s:DefaultPatternSet.path_abempty() abort
  return '\%(/' . self.segment() . '\)*'
endfunction
" path-absolute = "/" [ segment-nz *( "/" segment ) ]
function! s:DefaultPatternSet.path_absolute() abort
  return '/\%(' . self.segment_nz() . '\%(/' . self.segment() . '\)*\)\?'
endfunction
" path-noscheme = segment-nz-nc *( "/" segment )
function! s:DefaultPatternSet.path_noscheme() abort
  return self.segment_nz_nc() . '\%(/' . self.segment() . '\)*'
endfunction
" path-rootless = segment-nz *( "/" segment )
function! s:DefaultPatternSet.path_rootless() abort
  return self.segment_nz() . '\%(/' . self.segment() . '\)*'
endfunction

" scheme = ALPHA *( ALPHA / DIGIT / "+" / "." / "-" )
function! s:DefaultPatternSet.scheme() abort
  return '[[:alpha:]][[:alpha:]0-9+.-]*'
endfunction
" userinfo = *( unreserved / pct-encoded / sub-delims / ":" )
function! s:DefaultPatternSet.userinfo() abort
  return '\%(' . join([self.unreserved(), self.pct_encoded(),
  \                    self.sub_delims(), ':'], '\|') . '\)*'
endfunction
" host = IP-literal / IPv4address / reg-name
function! s:DefaultPatternSet.host() abort
  return '\%(' . join([self.ip_literal(), self.ipv4address(),
  \                    self.reg_name()], '\|') . '\)'
endfunction
" port = *DIGIT
function! s:DefaultPatternSet.port() abort
  return '[0-9]*'
endfunction
" path = path-abempty    ; begins with "/" or is empty
"      / path-absolute   ; begins with "/" but not "//"
"      / path-noscheme   ; begins with a non-colon segment
"      / path-rootless   ; begins with a segment
"      / path-empty      ; zero characters
function! s:DefaultPatternSet.path() abort
  return '\%(' . join([self.path_abempty(), self.path_absolute(),
  \                    self.path_noscheme(), self.path_rootless(),
  \                    ''], '\|') . '\)'
endfunction
" query = *( pchar / "/" / "?" )
function! s:DefaultPatternSet.query() abort
  return '\%(' . join([self.pchar(), '/', '?'], '\|') . '\)*'
endfunction
" fragment = *( pchar / "/" / "?" )
function! s:DefaultPatternSet.fragment() abort
  return '\%(' . join([self.pchar(), '/', '?'], '\|') . '\)*'
endfunction

" ================= s:DefaultPatternSet ==================

" vim:set et ts=2 sts=2 sw=2 tw=0:fen:
