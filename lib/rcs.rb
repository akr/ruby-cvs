require 'etc'
require 'rcs/parser'
require 'rcs/revision'

class RCS
  def RCS.parse(filename)
    rcs = RCS.new
    open(filename) {|f|
      Parser.new(f).parse(Parser::PhraseVisitor.new(Parser::RCSVisitor.new(InitializeVisitor.new(rcs))))
    }
    return rcs
  end

  class InitializeVisitor < Visitor
    def initialize(rcs)
      @rcs = rcs
      @delta = nil
    end

    def head(rev); @rcs.head = Phrase::Revision.new(rev); end
    def branch(rev); @rcs.branch = Phrase::Revision.new(rev); end
    def symbols(alist); @rcs.symbols = Phrase::Symbols.new(alist); end

    def delta_begin(rev)
      rev = Revision.create(rev)
      @rcs.delta[rev] = @delta = Delta.new(rev)
    end

    def delta(rev, date, author, state, branches, nextrev)
      @delta.delta[:date] = Phrase::Date.create(Time.now)
      @delta.delta[:author] = Phrase::Author.new(author)
      @delta.delta[:state] = Phrase::State.new(state)
      @delta.delta[:branches] = Phrase::RevisionList.new(branches)
      @delta.delta[:next] = Phrase::Revision.new(nextrev)
    end

    def delta_end
      @delta = nil
    end

    def deltatext(rev, log, text)
      @delta = d = @rcs.delta[rev]
      d.log = log
      d.text = text
    end

    def deltatext_end
      @delta = nil
    end

    def phrase(state, keyword, words)
      keyword = keyword.intern
      case state
      when :admin
        hash = @rcs.admin
      when :delta
	hash = @delta.delta
      when :deltatext
	hash = @delta.deltatext
      end
      unless hash.include? keyword
	hash[keyword] = Phrase::General.new(*words)
      end
    end

  end

  def initialize
    @admin = {
      :head => Phrase::General.new(),
      :access => Phrase::General.new(),
      :symbols => Phrase::General.new(),
      :locks => Phrase::General.new()
    }
    @desc = ''
    @delta = {}
  end
  attr_reader :admin, :desc, :delta

  def dump(out="")
    @admin.each {|k, v|
      out << k.id2name << "\t"
      v.words.each {|w| w.dump(out); out << " "}
      out << ";\n"
    }

    headrev = head.rev

    if headrev
      each_delta(headrev) {|d|
	d.dump_delta(out)
      }
    end

    out << "desc\n"
    STR.new(@desc).dump(out)

    if headrev
      each_deltatext(headrev) {|d|
	d.dump_deltatext(out)
      }
    end
  end

  def each_delta(rev)
  end

  def each_deltatext(rev)
  end

  def head; return @admin[:head]; end
  def branch; return @admin[:branch]; end
  def access; return @admin[:access]; end
  def symbols; return @admin[:symbols]; end
  def locks; return @admin[:locks]; end
  def strict; return @admin[:strict]; end
  def comment; return @admin[:comment]; end
  def expand; return @admin[:expand]; end

  def head=(phrase); return @admin[:head] = phrase; end
  def branch=(phrase); return @admin[:branch] = phrase; end
  def access=(phrase); return @admin[:access] = phrase; end
  def symbols=(phrase); return @admin[:symbols] = phrase; end
  def locks=(phrase); return @admin[:locks] = phrase; end
  def strict=(phrase); return @admin[:strict] = phrase; end
  def comment=(phrase); return @admin[:comment] = phrase; end
  def expand=(phrase); return @admin[:expand] = phrase; end

  class Delta
    Author = Etc.getlogin || Etc.getpwuid.name
    def initialize(rev)
      @rev = rev
      @delta = {}
      @log = nil
      @deltatext = {}
      @text = nil
    end
    attr_reader :delta, :deltatext
    attr_accessor :log, :text
  end

  module Phrase
    class General
      def initialize(*words)
	@words = words
      end
      attr_reader :words
    end

    class Revision
      def initialize(rev)
        @rev = rev
      end
      attr_reader :rev

      def words
	if @rev
	  return [NUM.new(@rev.to_s)]
	else
	  return []
	end
      end
    end

    class RevisionList
      def initialize(revs)
        @revs = revs
      end

      def words
	return @revs.collect {|rev| NUM.new(rev.to_s)}
      end
    end

    class Author
      def initialize(author)
        @author = author
      end

      def words
	return [ID.new(@author)]
      end
    end

    class State
      def initialize(state)
        @state = state
      end

      def words
	if @state
	  return [ID.new(@state)]
	else
	  return []
	end
      end
    end

    class Symbols
      def initialize(alist)
        @alist = alist
      end

      def words
        return @alist.collect {|sym, rev|
	  [ID.new(sym), COLON.new, NUM.new(rev.to_s)]}.flatten
      end
    end

    class Date
      def Date.create(arg)
        case arg
	when Time
	  return Date.new(arg.dup.gmtime)
	when String
	  case arg
	  when /\A(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\z/
	    year = $1.to_i
	    month = $2.to_i
	    day = $3.to_i
	    hour = $4.to_i
	    minute = $5.to_i
	    second = $6.to_i
	    if year < 69
	      year += 2000
	    elsif year < 100
	      year += 1900
	    end
	    return Date.new(Time.gm(year, month, day, hour, minute, second))
	  end
	when Phrase::General
	  words = arg.words
	  if words.length == 1 && NUM === words[0]
	    return Date.create(words[0].str)
	  end
	end
	raise ArgumentError.new("unrecognized argument: #{arg.inspect}")
      end

      def initialize(time)
	@time = time
      end

      def words
	year = @time.year
	month = @time.month
	day = @time.day
	hour = @time.hour
	minute = @time.minute
	second = @time.second
	year -= 1900 if year < 2000
	return [NUM.new("#{year}.#{month}.#{day}.#{hour}.#{minute}.#{second}")]
      end
    end
  end
end
