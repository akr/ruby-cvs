require 'etc'
require 'rcs/revision'
require 'rcs/parser'
require 'rcs/text'
require 'rcs/annotate'
require 'diff'
require 'tempdir'

begin
  require 'rcs/flex'
rescue LoadError
end

class RCS
  Author = Etc.getlogin || Etc.getpwuid.name

  def RCS.parse(filename)
    rcs = RCS.new
    File.open(filename) {|f|
      Parser.new(f).parse(
        Parser::PhraseVisitor.new(
	  Parser::RCSVisitor.new(
	    InitializeVisitor.new(rcs))))
    }

    rcs.each_delta {|d|
      rev = d.rev
      if r = d.nextrev
        rcs[r].prevrev = rev
      end
      d.branches.each {|r|
        rcs[r].prevrev = rev
      }
    }

    return rcs
  end

  class NotExist < StandardError
  end
  def RCS.update(filename)
    # xxx: race condition.
    raise NotExist.new("RCS file not exist: #{filename}") unless FileTest.exist? filename
    rcs = RCS.parse(filename)
    yield rcs
    rcs.write(filename)
  end

  class AlreadyExist < StandardError
  end
  def RCS.create(filename)
    # xxx: race condition.
    raise AlreadyExist.new("RCS file already exist: #{filename}") if FileTest.exist? filename
    rcs = yield
    rcs.write(filename)
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
      @rcs[rev] = @delta = Delta.new(rev)
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
      @delta = @rcs[rev]
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

  def initialize(desc='')
    @admin_phrase = {}
    @desc = desc
    @delta = {}
    @branch2head = {}

    @head = nil
    @branch = nil
    @symbols = []
    @locks = []
  end
  attr_reader :admin_phrase, :desc
  attr_accessor :head, :branch, :symbols, :locks

  def desc=(str)
    @desc = str
    @desc += "\n" if /[^\n]\z/ =~ str
  end

  def attic?
    return @delta[@head].state == 'dead'
  end

  def [](rev)
    return @delta[rev]
  end

  def []=(rev, d)
    @delta[rev] = d
    b = rev.on_trunk? ? nil : rev.branch
    if @branch2head.include? b
      r = @branch2head[b]
      @branch2head[b] = rev if r < rev
    else
      @branch2head[b] = rev
    end
  end

  class WriteFailure < StandardError
  end
  def write(filename)
    tmpname = File.dirname(filename) + '/,' + File.basename(filename, ",v") + ','
    begin
      f = File.open(tmpname, File::Constants::WRONLY |
			     File::Constants::TRUNC |
			     File::Constants::CREAT |
			     File::Constants::EXCL)
    rescue Errno::EEXIST
      raise WriteFailure.new("temporary file already exist: #{tmpname}")
    end

    renamed = false
    begin
      self.dump(f)
      f.close
      File.rename(tmpname, filename)
      renamed = true
    ensure
      File.unlink tmpname unless renamed
    end
  end

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

    return out
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

  class RevisionNotExist < StandardError
  end
  def checkout(rev)
    d = @delta[rev]
    raise RevisionNotExist.new("checkout non-existing revision #{rev}") unless d
    mtime = d.date
    ds = []
    until d == nil
      ds << d
      d = @delta[d.prevrev]
    end

    t = Text.new(ds.pop.text)
    until ds.empty?
      t.patch!(ds.pop.text)
    end

    return t.to_s, mtime
  end

  def RCS.diff(a, b)
    return Diff.rcsdiff(a, b)
  end

  def mkrev(contents, log, author=nil, date=nil, state=nil, rev=nil, delta_phrases={}, deltatext_phrases={})
    author ||= Author
    date ||= Time.now
    state ||= 'Exp'

    unless rev
      rev = @head ? @head.next : Revision.create('1.1')
    end

    if rev.on_trunk?
      if @head
	prevrev = @head
      else
        prevrev = nil
      end
    else
      if @branch2head.include? rev.branch
	prevrev = @branch2head[rev.branch]
      else
	prevrev = rev.origin
      end
    end

    if rev.on_trunk?
      branch = nil
    else
      branch = rev.branch
    end
    if prevrev
      raise StandardError.new("#{prevrev} is not on #{branch}") unless prevrev.on? branch
      raise StandardError.new("#{prevrev} is not after #{rev}") if rev <= prevrev
    end

    d = Delta.new(rev)
    d.date = date.dup.utc
    d.author = author
    d.state = state
    d.log = log
    delta_phrases.each {|k, v| d.delta_phrase[k] = v}
    deltatext_phrases.each {|k, v| d.deltatext_phrase[k] = v}

    @delta[rev] = d
    if rev.on_trunk?
      d.nextrev = prevrev
      d.text = contents
      if @head
	prevdelta = @delta[prevrev]
	prevcontents, mtime = checkout(prevrev)
	prevdelta.text = RCS.diff(contents, prevcontents)
	prevdelta.prevrev = rev
      end
      @head = rev
    else
      prevdelta = @delta[prevrev]
      prevcontents, mtime = checkout(prevrev)
      if prevrev == rev.origin
	prevdelta.branches << rev
      else
	prevdelta.nextrev = rev
      end
      d.text = RCS.diff(prevcontents, contents)
      d.prevrev = prevrev
    end
    @branch2head[branch] = rev
    return self
  end

  class Delta
    def initialize(rev)
      @num = 0
      @prevrev = nil
      @rev = rev
      @date = nil
      @author = nil
      @state = nil
      @branches = []
      @nextrev = nil
      @delta_phrase = {}
      @log = nil
      @deltatext_phrase = {}
      @text = nil
    end
    attr_reader :rev, :delta_phrase, :deltatext_phrase, :log
    attr_accessor :num, :prevrev
    attr_accessor :date, :author, :state, :branches, :nextrev, :text

    def log=(str)
      @log = str
      @log += "\n" if /[^\n]\z/ =~ str
    end

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
