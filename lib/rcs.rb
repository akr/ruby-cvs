require 'etc'
require 'rcs/revision'
require 'rcs/parser'
require 'rcs/text'

class RCS
  def RCS.parse(filename)
    rcs = RCS.new
    open(filename) {|f|
      Parser.new(f).parse(
        Parser::PhraseVisitor.new(
	  Parser::RCSVisitor.new(
	    InitializeVisitor.new(rcs))))
    }

    rcs.each_delta {|d|
      rev = d.rev
      if r = d.nextrev
        rcs.delta[r].prevrev = rev
      end
      d.branches.each {|r|
        rcs.delta[r].prevrev = rev
      }
    }

    return rcs
  end

  class InitializeVisitor < Visitor
    def initialize(rcs)
      @rcs = rcs
      @delta = nil
      @deltatextnum = 0
    end

    def head(rev); @rcs.head = rev; end
    def branch(rev); @rcs.branch = rev; end
    def symbols(alist); @rcs.symbols = alist; end
    def locks(alist); @rcs.locks = alist; end

    def delta_begin(rev)
      rev = Revision.create(rev)
      @rcs.delta[rev] = @delta = Delta.new(rev)
    end

    def delta(rev, date, author, state, branches, nextrev)
      @delta.date = date
      @delta.author = author
      @delta.state = state
      @delta.branches = branches
      @delta.nextrev = nextrev
    end

    def delta_end
      @delta = nil
    end

    def deltatext_begin(rev)
      rev = Revision.create(rev)
      @delta = @rcs.delta[rev]
      @delta.num = (@deltatextnum += 1)
    end

    def deltatext(rev, log, text)
      @delta.log = log
      @delta.text = text
    end

    def deltatext_end
      @delta = nil
    end

    def phrase(state, keyword, words)
      keyword = keyword.intern
      case state
      when :admin
        hash = @rcs.admin_phrase
      when :delta
	hash = @delta.delta_phrase
      when :deltatext
	hash = @delta.deltatext_phrase
      end
      hash[keyword] = words
    end

  end

  def initialize
    @admin_phrase = {}
    @desc = ''
    @delta = {}

    @head = nil
    @branch = nil
    @symbols = []
    @locks = []
  end
  attr_reader :admin_phrase, :desc, :delta
  attr_accessor :head, :branch, :symbols, :locks

  def dump(out="")
    hash = @admin_phrase.dup

    out << "head\t"
    out << @head.to_s if @head
    out << ";\n"
    hash.delete :head

    if @branch
      out << "branch\t"
      out << @branch.to_s
      out << ";\n"
    end
    hash.delete :branch

    out << "access"
    if hash.include? :access
      hash[:access].each {|w| out << "\n\t"; w.dump(out)}
    end
    out << ";\n"
    hash.delete :access

    out << "symbols"
    @symbols.each {|sym, rev|
      out << "\n\t" << sym << ":" << rev.to_s
    }
    out << ";\n"
    hash.delete :symbols

    out << "locks"
    @locks.each {|user, rev|
      out << "\n\t" << user << ":" << rev.to_s
    }
    if hash.include? :strict
      out << "; strict"
    end
    out << ";\n"
    hash.delete :locks
    hash.delete :strict

    if hash.include? :comment
      out << "comment"
      hash[:comment].each {|w| out << "\t"; w.dump(out)}
      out << ";\n"
    end
    hash.delete :comment

    if hash.include? :expand
      out << "expand"
      hash[:expand].each {|w| out << "\t"; w.dump(out)}
      out << ";\n"
    end
    hash.delete :expand

    hash.each {|keyword, words|
      out << keyword << "\t"
      words.each {|w| out << "\n\t"; w.dump(out)}
      out << ";\n"
    }

    out << "\n"

    if @head
      each_delta {|d|
	d.dump_delta(out)
      }
    end

    out << "\n\ndesc\n" << STR.quote(@desc) << "\n"

    if @head
      each_deltatext {|d|
	d.dump_deltatext(out)
      }
    end
  end

  def each_delta(rev=@head, &block)
    d = @delta[rev]
    yield d
    nextrev = d.nextrev
    each_delta(nextrev, &block) if nextrev
    d.branches.each {|r| each_delta(r, &block)}
  end

  def each_deltatext(rev=@head, &block)
    d = @delta[rev]
    yield d

    revs = d.branches
    nextrev = d.nextrev
    revs << nextrev if nextrev
    revs.sort! {|a, b| @delta[a].num <=> @delta[b].num}
    revs.each {|r| each_deltatext(r, &block)}
  end

  def checkout(rev)
    d = @delta[rev]
    ds = []
    until d == nil
      ds << d
      d = @delta[d.prevrev]
    end

    t = Text.new(ds.pop.text)
    until ds.empty?
      t.patch!(ds.pop.text)
    end

    return t.to_s
  end

  class Delta
    Author = Etc.getlogin || Etc.getpwuid.name
    def initialize(rev)
      @num = 0
      @prevrev = nil
      @rev = rev
      @date = nil
      @author = nil
      @state = nil
      @branches = nil
      @nextrev = nil
      @delta_phrase = {}
      @log = nil
      @deltatext_phrase = {}
      @text = nil
    end
    attr_reader :rev, :delta_phrase, :deltatext_phrase
    attr_accessor :num, :prevrev
    attr_accessor :date, :author, :state, :branches, :nextrev, :log, :text

    def dump_delta(out)
      hash = @delta_phrase

      out << "\n" << @rev.to_s << "\n"

      out << "date\t";
      y = @date.year
      y -= 1900 if y < 2000
      out << sprintf("%d.%02d.%02d.%02d.%02d.%02d",
        y, @date.month, @date.day, @date.hour, @date.min, @date.sec)
      out << ";\t"
      hash.delete :date

      out << "author " << @author << ";\t"
      hash.delete :author

      out << "state " << @state << ";\n"
      hash.delete :state

      out << "branches"
      @branches.each {|b|
	out << "\n\t" << b.to_s
      }
      out << ";\n"
      hash.delete :branches

      out << "next\t" << @nextrev.to_s << ";\n"
      hash.delete :next

      hash.each {|keyword, words|
	out << keyword << "\t"
	words.each {|w| out << "\n\t"; w.dump(out)}
	out << ";\n"
      }

    end

    def dump_deltatext(out)
      hash = @deltatext_phrase

      out << "\n\n" << @rev.to_s << "\n"
      out << "log\n" << STR.quote(@log) << "\n"

      hash.each {|keyword, words|
	out << keyword << "\t"
	words.each {|w| out << "\n\t"; w.dump(out)}
	out << ";\n"
      }

      out << "text\n" << STR.quote(@text) << "\n"
    end
  end
end
