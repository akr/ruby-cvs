class CVS
  class Visitor
    def method_missing(msg_id, *args)
      # Events which has no handler is ignored.
    end

    class Dump < Visitor
      def initialize(output=STDOUT)
	@out = output
      end

      def method_missing(msg_id, *args)
	@out.print msg_id, args.inspect, "\n"
      end
    end
  end

  module Parser
    module Buffer
      def initialize_buffer(input)
	@in = input
	@buf = ''
	@eof = false
      end

      def eof?
	return false unless @buf.empty?
	return true if @eof
	return @in.eof?
      end

      def readmore
	return @in.readline
      end

      def fillbuf(len)
	return if @eof
	while !@eof && @buf.length < len
	  begin
	    @buf << readmore
	  rescue EOFError
	    @eof = true
	  end
	end
      end

      def fillbuf_byte(re)
	return $~ if re =~ @buf
	while !@eof
	  begin
	    @buf << (s = readmore)
	    if re =~ s
	      re =~ @buf
	      return $~
	    end
	  rescue EOFError
	    @eof = true
	  end
	end
	raise ScanError.new("expected: #{re.inspect}")
      end

      def fillbuf_regex(re)
	return $~ if re =~ @buf
	while !@eof
	  fillbuf(@buf.length + 1)
	  return $~ if re =~ @buf
	end
	raise ScanError.new("expected: #{re.inspect}")
      end

      def fillbuf_line
	return fillbuf_byte(/\n/)
      end

      def skip(len)
	raise ScanError.new("scan buffer has only #{@buf.length} bytes but #{len} bytes required") if @buf.length < len
	@buf[0, len] = ''
      end

      def match_string(str)
	fillbuf(str.length)
	raise ScanError.new("expected: #{str.inspect}") if @buf[0, str.length] != str
	skip(str.length)
	return str
      end

      def match_byte(re)
	m = fillbuf_byte(re)
	skip(m.end(0))
	return m
      end

      def match_regex(re)
	m = fillbuf_regex(re)
	skip(m.end(0))
	return m
      end

      def match_line
	return match_regex(/\n/).pre_match
      end

      def match_regex_now(re)
	if m = re.match(@buf)
	  skip(m.end(0))
	  return m
	else
	  raise ScanError.new("expected: #{re.inspect}")
	end
      end

      def try(val=nil)
	begin
	  return yield
	rescue ScanError
	  return val
	end
      end

      class ScanError < StandardError
      end
    end

    # cat foo,v|ruby -rcvs -e 'CVS::Parser::RCS.new.parse(CVS::Visitor::Dump.new)'
    class RCS
      def initialize(input=STDIN)
	@scanner = @@scanner.new(input)

	@admin_phrase_parser = {
	  'head' => lambda {|visitor|
	    head = try {get_num.str}
	    match_semi
	    visitor.head(head)
	    head
	  },
	  'branch' => lambda {|visitor|
	    branch = try {get_num.str}
	    match_semi
	    visitor.branch(branch)
	    branch
	  },
	  'access' => lambda {|visitor|
	    ids = []
	    while id = try {get_id.str}
	      ids << id
	      visitor.access(id)
	    end
	    match_semi
	    ids
	  },
	  'symbols' => lambda {|visitor|
	    syms = {}
	    while sym = try {get_sym.str}
	      match_colon
	      num = get_num.str
	      syms[sym] = num
	      visitor.symbol(sym, num)
	    end
	    match_semi
	    syms
	  },
	  'locks' => lambda {|visitor|
	    locks = {}
	    while id = try {get_id.str}
	      match_colon
	      num = get_num.str
	      locks[id] = num
	      visitor.lock(id, num)
	    end
	    match_semi
	    locks
	  },
	  'strict' => lambda {|visitor|
	    match_semi
	    visitor.lock_strict
	    true
	  },
	  'comment' => lambda {|visitor|
	    comment = try {get_str.str}
	    match_semi
	    comment
	  },
	  'expand' => lambda {|visitor|
	    expand = try {get_str.str}
	    match_semi
	    visitor.expand(expand)
	    expand
	  },
	}
	@delta_phrase_parser = {
	  'date' => lambda {|visitor|
	    date = get_num.str
	    match_semi
	    date
	  },
	  'author' => lambda {|visitor|
	    author = get_id.str
	    match_semi
	    author
	  },
	  'state' => lambda {|visitor|
	    state = try {get_id.str}
	    match_semi
	    state
	  },
	  'branches' => lambda {|visitor|
	    branches = []
	    while num = try {get_num.str}
	      branches << num
	    end
	    match_semi
	    branches
	  },
	  'next' => lambda {|visitor|
	    nextrev = try {get_num.str}
	    match_semi
	    nextrev
	  },
	}

	@deltatext_phrase_parser = {
	}
      end

      def try(val=nil)
	begin
	  return yield
	rescue ScanError
	  return val
	end
      end
      class ScanError < StandardError
      end

      def parse(visitor)
	visitor.admin(parse_phrases(visitor, @admin_phrase_parser))
	nil while parse_delta(visitor)
	visitor.delta_finished
	parse_desc(visitor)
	nil while parse_deltatext(visitor)
	return visitor.finished
      end

      def parse_delta(visitor)
        if rev = try {get_num}
	  hash = parse_phrases(visitor, @delta_phrase_parser)
	  visitor.delta(rev.str, hash)
	  return true
	else
	  return false
	end
      end

      def parse_desc(visitor)
	match_id('desc')
	visitor.description(get_str.str)
      end

      def parse_deltatext(visitor)
        if rev = try {get_num}
	  match_id('log')
	  log = get_str
	  hash = parse_phrases(visitor, @deltatext_phrase_parser)
	  match_id('text')
	  text = get_str
	  visitor.deltatext(rev.str, log.str, hash, text.str)
	  #visitor.deltatext_log(rev.str, log.str)
	  return true
	else
	  return false
	end
      end

      def parse_phrases(visitor, phrase_parser = {})
	hash = {}
	while pair = parse_phrase(visitor, phrase_parser)
	  hash[pair[0]] = pair[1]
	end
	return hash
      end

      def parse_phrase(visitor, phrase_parser = {})
        t = get
	unless ID === t
	  unget t
	  return false
	end
	case t.str
	when 'desc', 'text'
	  unget t
	  return false
	end

	key = t.str
	if phrase_parser.key? key
	  val = phrase_parser[key].call(visitor)
	else
	  val = []
	  while t = try {get_word}
	    val << t
	  end
	  match_semi
	end
	return [key, val]
      end

      def match_id(s)
        t = get_id
	unless t.str == s
	  unget t
	  raise ScanError.new("#{s.inspect} expected: #{t.inspect}")
	end
	return t
      end

      def match_semi
        t = get
	unless SEMI === t
	  unget t
	  raise ScanError.new("';' expected: #{t.inspect}")
	end
	return t
      end

      def match_colon
        t = get
	unless COLON === t
	  unget t
	  raise ScanError.new("':' expected: #{t.inspect}")
	end
	return t
      end

      def get_word
        t = get
	case t
	when ID, NUM, STR, COLON
	  return t
	else
	  unget t
	  raise ScanError.new("word expected: #{t.inspect}")
	end
      end

      def get_str
	if STR === (t = get)
	  return t
	else
	  unget t
	  raise ScanError.new("str expected: #{t.inspect}")
	end
      end

      def get_sym
        t = get_id
	unless /\A([!"\#%&'()*+\-\/0123456789<=>?A-Z\[\\\]^_`a-z{|}~\240-\377]+)\z/ =~ t.str
	  raise ScanError.new("sym expected: #{t.inspect}")
	end
	return t
      end

      def get_id
	if ID === (t = get)
	  return t
	else
	  unget t
	  raise ScanError.new("num expected: #{t.inspect}")
	end
      end

      def get_num
	if NUM === (t = get)
	  return t
	else
	  unget t
	  raise ScanError.new("num expected: #{t.inspect}")
	end
      end

      def unget(t)
        @saved_token = t
      end

      def get
	if @saved_token
	  t = @saved_token
	  @saved_token = nil
	  return t
	end

	return @scanner.get
      end

      class Scanner
        def initialize(input)
	  @in = input
	  @line = ''
	end

	def joinstrings(ss)
	  l = 0
	  ss.each {|s|
	    l += s.length
	  }
	  result = ' ' * l
	  i = 0
	  ss.each {|s|
	    result[i, s.length] = s
	    i += s.length
	  }
	  return result
	end

	def get
	  while @line == ''
	    begin
	      @line = @in.readline
	    rescue EOFError
	      return nil
	    end
	    @line.sub!(/\A[ \b\t\n\v\f\r]*/, '')
	  end
	  if @line.sub!(/\A([!"\#%&'()*+\-.\/0123456789<=>?A-Z\[\\\]^_`a-z{|}~\240-\377]+)[ \b\t\n\v\f\r]*/, '')
	    t = $1
	    if /\A[0-9.]*\z/ =~ t
	      return NUM.new(t)
	    else
	      return ID.new(t)
	    end
	  elsif @line.sub!(/\A@/, '')
	    s = []
	    # scan the first line.
	    while @line.sub!(/\A([^@]*)@(@|[ \b\t\n\v\f\r]*)/, '')
	      s << $1
	      if $2 == '@'
		s << '@'
	      else
		return STR.new(joinstrings(s))
	      end
	    end
	    s << @line
	    # scan continued lines.
	    while true
	      seg = begin
		      @in.readline('@')
		    rescue EOFError
		      raise ScanError.new("RCS string not terminated.")
		    end
	      ch = begin
		     @in.readchar
		   rescue EOFError
		     unless seg.chomp!('@')
		       raise ScanError.new("RCS string not terminated.")
		     end
		     s << seg
		     @line = ''
		     return STR.new(joinstrings(s))
		   end
	      if ch == ?@
		s << seg
	      else
		seg.chomp!('@')
		s << seg
		@in.ungetc(ch)
		@line = ''
		return STR.new(joinstrings(s))
	      end
	    end
	  elsif @line.sub!(/\A;[ \b\t\n\v\f\r]*/, '')
	    return SEMI.new(';')
	  elsif @line.sub!(/\A:[ \b\t\n\v\f\r]*/, '')
	    return COLON.new(':')
	  else
	    raise ScanError.new("could not extract RCS token: #{@line.inspect}")
	  end
	end
      end
      @@scanner = Scanner

      class Token
        def initialize(s)
	  @str = s
	end
	attr_reader :str
      end

      class STR < Token
      end

      class ID < Token
      end

      class NUM < Token
      end

      class COLON < Token
      end

      class SEMI < Token
      end

      class RCSVisitor < Visitor
        def initialize(visitor)
	  @visitor = visitor
	end

	def method_missing(msg_id, *args)
	  @visitor.send(msg_id, *args)
	end

	def head(rev)
	  rev = Revision.create(rev)
	  @visitor.head(rev)
	end

	def branch(rev)
	  rev = Revision.create(rev)
	  @visitor.branch(rev)
	end

	def lock(user, rev)
	  rev = Revision.create(rev)
	  @visitor.lock(user, rev)
	end

	def symbol(sym, rev)
	  rev = Revision.create(rev)
	  @visitor.symbol(sym, rev)
	end

	def delta(rev, hash)
	  @visitor.delta_rcs(rev, hash)
	  rev = Revision.create(rev)
	  date = hash['date']
	  if /\A(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\z/ =~ date
	    y = $1.to_i
	    y += 1900 if y < 100
	    date = Time.gm(y, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i)
	  else
	    raise RCSDateFormatError.new(date)
	  end
	  branches = hash['branches'].collect {|r| Revision.create(r)}
	  @visitor.delta_without_next(
	    rev,
	    date,
	    hash['author'],
	    hash['state'],
	    branches)
	  @visitor.delta(
	    rev,
	    date,
	    hash['author'],
	    hash['state'],
	    branches,
	    Revision.create(hash['next']))
	end

	def deltatext(rev, log, hash, text)
	  @visitor.deltatext_rcs(rev, log, hash, text)
	  rev = Revision.create(rev)
	  @visitor.deltatext_log(rev, log)
	  @visitor.deltatext(rev, log, text)
	end

	class LogDateFormatError < StandardError
	end
      end
    end

    # rlog foo,v|ruby -rcvs -e 'CVS::Parser::Log.new.parse(CVS::Visitor::Dump.new)'
    class Log
      include Buffer

      def initialize(input=STDIN)
	initialize_buffer(input)
      end

      def parse(visitor)
	match_string("\nRCS file: ")
	visitor.rcsfile(match_line)

	if try {match_string("Working file: ")}
	  visitor.working_file(match_line)
	end

	match_string("head:")
	if try {match_string(" ")}
	  visitor.head(match_line)
	else
	  visitor.head(nil)
	end

	match_string("branch:")
	if try {match_string(" ")}
	  visitor.branch(match_line)
	else
	  visitor.branch(nil)
	  match_string("\n")
	end

	match_string("locks:")
	if try {match_string(" strict")}
	  visitor.lock_strict
	end
	match_string("\n")
	while true
	  break unless try {match_string("\t")}
	  user = match_regex(/: /).pre_match
	  rev = match_line
	  visitor.lock(user, rev)
	end
	match_string("access list:\n")
	while true
	  break unless try {match_string("\t")}
	  user = match_line
	  visitor.access(user)
	end

	if try {match_string("symbolic names:\n")}
	  while true
	    break unless try {match_string("\t")}
	    sym = match_regex(/: /).pre_match
	    rev = match_line
	    visitor.symbol(sym, rev)
	  end
	end

	match_string("keyword substitution: ")
	visitor.expand(match_line)

	match_string("total revisions: ")
	fillbuf_line
	visitor.total_revisions(match_regex_now(/\A[^;\n]*/)[0])
	if m = try {match_string(";\tselected revisions: ")}
	  visitor.selected_revisions(match_line)
	else
	  match_string("\n")
	end

	if try {match_string("description:\n")}
	  visitor.description(match_message)
	end


	while try {match_string("----------------------------\nrevision ")}
	  m = fillbuf_regex(/\tlocked by: |\n/)
	  rev = m.pre_match
	  skip(m.begin(0))
	  if try {match_string("\tlocked by: ")}
	    locked_by = match_byte(/;/).pre_match
	  else
	    locked_by = nil
	  end
	  match_string("\ndate: ")
	  fillbuf_line
	  date = match_regex_now(/;  author: /).pre_match
	  author = match_regex_now(/;  state: /).pre_match
	  state = match_regex_now(/;/).pre_match
	  if m = try {match_string("  lines: +")}
	    add = match_regex_now(/ -/).pre_match
	    del = match_line
	  else
	    add = del = nil
	    match_line
	  end
	  branches = []
	  if m = try {match_string("branches:")}
	    while try {match_string("  ")}
	      branches << match_byte(/;/).pre_match
	    end
	    match_string("\n")
	  end
	  message = match_message
	  visitor.delta_rlog(rev, locked_by, date, author, state, add, del, branches, message)
	end

	# FreeBSD's rlog outputs extra "---...---\n" before "===...===\n".
	unless try {match_string("----------------------------\n\
=============================================================================\n")}
	  match_string("=============================================================================\n")
	end

	return visitor.finished(@buf)
      end

      def match_message
	# if revision info. is followed:
	#   /\n---...---\nrevision /
	# if revision info. is not exist:
	#   /\n===...===\n/
	# if revision info. is not exist and it is FreeBSD's rlog output:
	#   /\n---...---\n===...===\n/
	m = fillbuf_regex(/(\A|\n)\
(----------------------------\n\
(revision |=============================================================================\n)|\
=============================================================================\n)/)
	skip(m.end(1))
	return m.pre_match + m[1]
      end

      class LogVisitor < Visitor
        def initialize(visitor)
	  @visitor = visitor
	end

	def method_missing(msg_id, *args)
	  @visitor.send(msg_id, *args)
	end

	def head(rev)
	  rev = Revision.create(rev)
	  @visitor.head(rev)
	end

	def branch(rev)
	  rev = Revision.create(rev)
	  @visitor.branch(rev)
	end

	def lock(user, rev)
	  rev = Revision.create(rev)
	  @visitor.lock(user, rev)
	end

	def symbol(sym, rev)
	  rev = Revision.create(rev)
	  @visitor.symbol(sym, rev)
	end

	def total_revisions(n)
	  @visitor.total_revisions(n.to_i)
	end

	def selected_revisions(n)
	  @visitor.selected_revisions(n.to_i)
	end

	def delta_rlog(rev, locked_by, date, author, state, add, del, branches, message)
	  rev = Revision.create(rev)
	  if /\A(\d\d\d\d)\/(\d\d)\/(\d\d) (\d\d):(\d\d):(\d\d)\z/ =~ date
	    date = Time.gm($1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i)
	  else
	    raise LogDateFormatError.new(date)
	  end
	  state = nil if state == ''
	  add = add.to_i if add
	  del = del.to_i if del
	  branches = branches.collect {|r| Revision.create(r)}
	  @visitor.delta_rlog(rev, locked_by, date, author, state, add, del, branches, message)
	  @visitor.delta_without_next(rev, date, author, state, branches)
	  @visitor.deltatext_log(rev, message)
	end
	class LogDateFormatError < StandardError
	end
      end

      class FormatCheckVisitor < Visitor
	def initialize(input=nil)
	  @in = input
	  @delta_count = 0
	end

	def rcsfile(arg)
	  raise RCSFormatError.new(arg) unless arg =~ /\A\/?([^\/]+\/)*([^\/]+),v\z/
	  @working_file = $2
	end

	def working_file(arg)
	  raise RCSFormatError.new(arg) unless arg == @working_file
	end

	def head(arg)
	  checkrev(arg)
	end

	def branch(arg)
	  checkrev(arg)
	end

	def lock(user, rev)
	  checkid(user)
	  checkrev(rev)
	end

	def access(user)
	  checkid(user)
	end

	def symbol(sym, rev)
	  checktag(sym)
	  checkrev(rev)
	end

	def expand(arg)
	  raise RCSFormatError.new(arg) unless arg =~ /\A(kv|kvl|k|o|b|v)\z/
	end

	def total_revisions(arg)
	  raise RCSFormatError.new(arg) unless arg =~ /\A\d+\z/
	  @total_revisions = arg.to_i
	end

	def selected_revisions(arg)
	  raise RCSFormatError.new(arg) unless arg =~ /\A\d+\z/
	  @selected_revisions = arg.to_i
	  raise RCSFormatError.new(arg) unless @selected_revisions <= @total_revisions
	end

	def delta_rlog(rev, locked_by, date, author, state, add, del, branches, message)
	  @delta_count += 1
	  checkrev(rev)
	  checkid(locked_by) if locked_by
	  raise RCSFormatError.new(date) unless date =~ /\A\d\d\d\d\/\d\d\/\d\d \d\d:\d\d:\d\d\z/
	  checkid(author)
	  checkid(state)
	  raise FormatError.new(add) unless add =~ /\A\d+\z/ if add
	  raise FormatError.new(del) unless del =~ /\A\d+\z/ if del
	  branches.each {|branch| checkrev(branch)}
	end

	def finished(buf)
	  if @selected_revisions
	    raise FormatError.new("number of deltas(#{@delta_count}) is not matched to selected_revisions(#{@selected_revisions})") if @selected_revisions != @delta_count
	  end
	  if buf != ''
	    raise FormatError.new("buffer has data: #{buf}")
	  end
	  if @in && d = @in.read
	    raise FormatError.new("data is remained: #{d}")
	  end
	end

	def checknum(s)
	  raise RCSFormatError.new(s) unless s =~ /\A[0-9.]+\z/
	end

	def checkid(s)
	  raise RCSFormatError.new(s) unless s =~ /\A\.*[!-#%-+\-\/-9<-?A-~][!-#%-+\--9<-?A-~]*\z/
	end

	def checksym(s)
	  raise RCSFormatError.new(s) unless s =~ /\A[!-#%-+\-\/-9<-?A-~]+\z/
	end

	def checktag(tag)
	  checksym(tag)
	  raise CVSFormatError.new(tag) unless tag =~ /\A[A-Za-z][A-Za-z0-9\-_]*\z/
	  # Some tags uses invalid characters.
	  #raise CVSFormatError.new(tag) unless tag =~ /\A[A-Za-z]["+A-Za-z0-9\-_]*\z/
	end

	def checkrev(rev)
	  checknum(rev)
	  raise CVSFormatError.new(rev) unless rev =~ /\A\d+(\.\d+)*\z/
	end

	class FormatError < StandardError
	end

	class RCSFormatError < FormatError
	end

	class CVSFormatError < FormatError
	end
      end
    end
  end
end
