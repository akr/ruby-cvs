require 'rcs/revision'

class RCS
  class Visitor
    def method_missing(msg_id, *args)
      # Events which has no handler is ignored.
    end

    class Dump < Visitor
      def initialize(output=STDOUT)
	@out = output
      end

      def method_missing(msg_id, *args)
	if args.empty?
	  @out.print msg_id, "\n"
	else
	  @out.print msg_id, args.inspect, "\n"
	end
      end
    end
  end

  class Token
    def initialize(s)
      @str = s
    end
    attr_reader :str
  end

  class STR < Token
    def STR.quote(str)
      return "@#{str.gsub(/@/, '@@')}@"
    end

    def dump(out="")
      out << STR.quote(@str)
    end
  end

  class ID < Token
    def dump(out="")
      out << @str
    end
  end

  class NUM < Token
    def dump(out="")
      out << @str
    end
  end

  class COLON < Token
    def initialize(s=':')
      super(s)
    end

    def dump(out="")
      out << ':'
    end
  end

  class SEMI < Token
    def initialize(s=';')
      super(s)
    end

    def dump(out="")
      out << ';'
    end
  end

  class Parser
    def initialize(input=STDIN)
      @scanner = @@scanner.new(input)
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
      visitor.admin_begin
      parse_phrases(visitor, :admin)
      visitor.admin_end

      visitor.delta_list_begin
      nil while parse_delta(visitor)
      visitor.delta_list_end

      parse_desc(visitor)

      visitor.deltatext_list_begin
      nil while parse_deltatext(visitor)
      visitor.deltatext_list_end

      return visitor.finished
    end

    def parse_delta(visitor)
      if rev = try {get_num}
	visitor.delta_begin(rev.str)
	parse_phrases(visitor, :delta)
	visitor.delta_end
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
	visitor.deltatext_begin(rev.str)
	match_id('log')
	log = get_str
	visitor.deltatext_log(log.str)
	parse_phrases(visitor, :deltatext)
	match_id('text')
	text = get_str
	visitor.deltatext_text(text.str)
	visitor.deltatext_end
	return true
      else
	return false
      end
    end

    def parse_phrases(visitor, state)
      nil while parse_phrase(visitor, state)
    end

    def parse_phrase(visitor, state)
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
      words = []
      while t = try {get_word}
        words << t
      end
      match_semi
      visitor.phrase(state, key, words)
      return true
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

    class PhraseVisitor
      def initialize(visitor)
        @visitor = visitor
	@adminparser = Admin.new(visitor)
	@deltaparser = Delta.new(visitor)
	@deltatextparser = DeltaText.new(visitor)
      end

      def method_missing(msg_id, *args)
	@visitor.send(msg_id, *args)
      end

      def phrase(state, keyword, words)
	@visitor.phrase(state, keyword, words)
	msg_id = "phrase_#{keyword}".intern
	case state
	when :admin;     @adminparser.send(msg_id, words)
	when :delta;     @deltaparser.send(msg_id, words)
	when :deltatext; @deltatextparser.send(msg_id, words)
	end
      end

      class Admin
        def initialize(visitor)
	  @visitor = visitor
	end

	def method_missing(msg_id, *args)
	end

	def phrase_head(words)
	  case words.length
	  when 0
	    @visitor.admin_head(nil)
	  when 1
	    unless NUM === words[0]
	      raise ScanError.new("invalid head phrase: #{words.inspect}")
	    end
	    @visitor.admin_head(words[0].str)
	  else
	    raise ScanError.new("head phrase has two or more words: #{words.inspect}")
	  end
	end

	def phrase_branch(words)
	  case words.length
	  when 0
	    @visitor.admin_branch(nil)
	  when 1
	    unless NUM === words[0]
	      raise ScanError.new("invalid branch phrase: #{words.inspect}")
	    end
	    @visitor.admin_branch(words[0].str)
	  else
	    raise ScanError.new("branch phrase has two or more words: #{words.inspect}")
	  end
	end

	def phrase_access(words)
	  words.each {|word|
	    unless ID === word
	      raise ScanError.new("invalid access phrase: #{words.inspect}")
	    end
	  }
	  @visitor.admin_access(words.collect {|t| t.str})
	end

	def phrase_symbols(words)
	  syms = []
	  i = 0
	  while i < words.length
	    if words.length <= i + 2
	      raise ScanError.new("symbols phrase has garbage words: #{words[i..-1].inspect}")
	    end
	    id = words[i+0] 
	    colon = words[i+1] 
	    num = words[i+2] 
	    unless ID === id
	      raise ScanError.new("invalid symbols phrase (first word is not ID): #{words[i..-1].inspect}")
	    end
	    unless COLON === colon
	      raise ScanError.new("invalid symbols phrase (second word is not COLON): #{words[i..-1].inspect}")
	    end
	    unless NUM === num
	      raise ScanError.new("invalid symbols phrase (third word is not NUM): #{words[i..-1].inspect}")
	    end

	    syms << [id.str, num.str]
	    i += 3
	  end
	  @visitor.admin_symbols(syms)
	end

	def phrase_locks(words)
	  locks = []
	  i = 0
	  while i < words.length
	    if words.length <= i + 2
	      raise ScanError.new("locks phrase has garbage words: #{words[i..-1].inspect}")
	    end
	    id = words[i+0] 
	    colon = words[i+1] 
	    num = words[i+2] 
	    unless ID === id
	      raise ScanError.new("invalid locks phrase (first word is not ID): #{words[i..-1].inspect}")
	    end
	    unless COLON === colon
	      raise ScanError.new("invalid locks phrase (second word is not COLON): #{words[i..-1].inspect}")
	    end
	    unless NUM === num
	      raise ScanError.new("invalid locks phrase (third word is not NUM): #{words[i..-1].inspect}")
	    end

	    locks << [id.str, num.str]
	    i += 3
	  end
	  @visitor.admin_locks(locks)
	end

	def phrase_strict(words)
	  if words.length != 0
	    raise ScanError.new("strict phrase has one or more words: #{words.inspect}")
	  end
	  @visitor.admin_strict
	end

	def phrase_comment(words)
	  case words.length
	  when 0
	    @visitor.admin_comment(nil)
	  when 1
	    unless STR === words[0]
	      raise ScanError.new("invalid comment phrase: #{words.inspect}")
	    end
	    @visitor.admin_comment(words[0].str)
	  else
	    raise ScanError.new("comment phrase has two or more words: #{words.inspect}")
	  end
	end

	def phrase_expand(words)
	  case words.length
	  when 0
	    @visitor.admin_expand(nil)
	  when 1
	    unless STR === words[0]
	      raise ScanError.new("invalid expand phrase: #{words.inspect}")
	    end
	    @visitor.admin_expand(words[0].str)
	  else
	    raise ScanError.new("expand phrase has two or more words: #{words.inspect}")
	  end
	end

      end

      class Delta
        def initialize(visitor)
	  @visitor = visitor
	end

	def method_missing(msg_id, *args)
	end

	def phrase_date(words)
	  unless words.length == 1 && NUM === words[0]
	    raise ScanError.new("invalid date phrase: #{words.inspect}")
	  end
	  @visitor.delta_date(words[0].str)
	end

	def phrase_author(words)
	  unless words.length == 1 && ID === words[0]
	    raise ScanError.new("invalid author phrase: #{words.inspect}")
	  end
	  @visitor.delta_author(words[0].str)
	end

	def phrase_state(words)
	  case words.length
	  when 0
	    @visitor.delta_state(nil)
	  when 1
	    unless ID === words[0]
	      raise ScanError.new("invalid state phrase: #{words.inspect}")
	    end
	    @visitor.delta_state(words[0].str)
	  else
	    raise ScanError.new("state phrase has two or more words: #{words.inspect}")
	  end
	end

	def phrase_branches(words)
	  words.each {|word|
	    unless NUM === word
	      raise ScanError.new("invalid branches phrase: #{words.inspect}")
	    end
	  }
	  @visitor.delta_branches(words.collect {|t| t.str})
	end

	def phrase_next(words)
	  case words.length
	  when 0
	    @visitor.delta_next(nil)
	  when 1
	    unless NUM === words[0]
	      raise ScanError.new("invalid next phrase: #{words.inspect}")
	    end
	    @visitor.delta_next(words[0].str)
	  else
	    raise ScanError.new("next phrase has two or more words: #{words.inspect}")
	  end
	end
      end

      class DeltaText
        def initialize(visitor)
	  @visitor = visitor
	end

	def method_missing(msg_id, *args)
	end
      end
    end

    class RCSVisitor < Visitor
      def initialize(visitor)
	@visitor = visitor
      end

      def method_missing(msg_id, *args)
	@visitor.send(msg_id, *args)
      end

      def admin_head(rev)
	@visitor.admin_head(rev)
        rev = rev && Revision.create(rev)
	@visitor.head(rev)
      end

      def admin_branch(rev)
	@visitor.admin_branch(rev)
        rev = rev && Revision.create(rev)
	@visitor.branch(rev)
      end

      def admin_locks(alist)
	@visitor.admin_locks(alist)
        alist = alist.collect {|user, rev| [user, Revision.create(rev)]}
        @visitor.locks(alist)
	alist.each {|user, rev| @visitor.lock(user, rev)}
      end

      def admin_symbols(alist)
	@visitor.admin_symbols(alist)
        alist = alist.collect {|sym, rev| [sym, Revision.create(rev)]}
        @visitor.symbols(alist)
	alist.each {|sym, rev| @visitor.symbol(sym, rev)}
      end

      def delta_begin(rev)
	@visitor.delta_begin(rev)
        @delta_rev = Revision.create(rev)
	@delta_date = nil
	@delta_author = nil
	@delta_state = nil
	@delta_branches = nil
	@delta_next = nil
      end

      def delta_date(date)
	@visitor.delta_date(date)
	unless /\A(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\z/ =~ date
	  raise RCSDateFormatError.new(date)
	end
	y = $1.to_i
	if y < 69
	  y += 2000
	elsif y < 100
	  y += 1900
	end
	@delta_date = Time.gm(y, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i)
      end

      def delta_author(author)
        @visitor.delta_author(author)
        @delta_author = author
      end

      def delta_state(state)
        @delta_state = state
      end

      def delta_branches(branches)
        @visitor.delta_branches(branches)
        @delta_branches = branches.collect {|r| Revision.create(r)}
      end

      def delta_next(rev)
        @visitor.delta_next(rev)
        @delta_next = rev  && Revision.create(rev)
      end

      def delta_end
        @visitor.delta_rlog(
	  @delta_rev,
	  @delta_date,
	  @delta_author,
	  @delta_state,
	  @delta_branches)
        @visitor.delta(
	  @delta_rev,
	  @delta_date,
	  @delta_author,
	  @delta_state,
	  @delta_branches,
	  @delta_next)
        @visitor.delta_end
      end

      def deltatext_begin(rev)
        @visitor.deltatext_begin(rev)
        @deltatext_rev = Revision.create(rev)
	@deltatext_log = nil
	@deltatext_text = nil
      end

      def deltatext_log(log)
        @visitor.deltatext_log(log)
        @deltatext_log = log
      end

      def deltatext_text(text)
        @visitor.deltatext_text(text)
        @deltatext_text = text
      end

      def deltatext_end
	@visitor.deltatext_rlog(@deltatext_rev, @deltatext_log)
	@visitor.deltatext(@deltatext_rev, @deltatext_log, @deltatext_text)
        @visitor.deltatext_end
      end
    end
  end
end
