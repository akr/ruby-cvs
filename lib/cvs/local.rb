require 'rcs'
require 'fcntl'
require 'socket' # to use gethostname

class CVS
  class L < R # local repository
    def initialize(cvsroot, readonly=false)
      super(cvsroot, readonly)
    end

    def top_dir
      return D.new(self, nil, '.')
    end

    class D < R::D
      Info = ".#{Socket.gethostname}.#{$$}"

      def initialize(cvsroot, parent, path)
        super(cvsroot, parent, path)

	@rcsdir = @cvsroot.cvsroot + '/' + @path

	# xxx: "#{@cvsroot.cvsroot}/CVSROOT/config" should be examined.
	@lockdir = @rcsdir
	@master_lock_file = "#{@lockdir}/\#cvs.lock"
	@read_lock_file = "#{@lockdir}/\#cvs.rfl#{Info}"
	@write_lock_file = "#{@lockdir}/\#cvs.wfl#{Info}"
	@lockstate = :unlock
      end

      def simple_dir(name)
	return D.new(@cvsroot, self, @path + '/' + name)
      end

      def simple_file(name, attic=nil)
	return F.new(self, name, attic)
      end

      def listdir
	res = []
	dir = @rcsdir
	read_lock {
	  Dir.foreach(dir) {|name|
	    next if /\A(\.|\.\.|CVS|Attic)\z/ =~ name
	    if FileTest.directory?(dir + '/' + name)
	      res << simple_dir(name)
	    end
	  }
	}
	return res
      end

      def listfile
	res = []
	dir = @rcsdir
	read_lock {
	  Dir.foreach(dir) {|name|
	    next if /\A(\.|\.\.|CVS|Attic)\z/ =~ name
	    if /,v\z/ =~ name && FileTest.file?(dir + '/' + name)
	      res << simple_file($`, false)
	    end
	  }
	  dir += '/Attic'
	  begin
	    Dir.foreach(dir) {|name|
	      next if /\A(\.|\.\.|CVS|Attic)\z/ =~ name
	      if /,v\z/ =~ name && FileTest.file?(dir + '/' + name)
		res << simple_file($`, true)
	      end
	    }
	  rescue Errno::ENOENT
	  end
	}
	return res
      end

      def parse_raw_log(visitor, opts=[])
	read_lock {
	  rcs_pathnames = listfile.collect {|f| f.rcs_pathname}
	  return if rcs_pathnames.empty?
	  with_work {|t|
	    r, w = IO.pipe
	    pid = fork {
	      STDOUT.reopen(w)
	      File.open('/dev/null', 'w') {|f| STDERR.reopen(f)}
	      r.close
	      w.close
	      Dir.chdir(t.path)
	      command = ['rlog']
	      command += opts
	      command += rcs_pathnames
	      exec *command
	    }
	    w.close
	    parser = Parser::Log.new(r)
	    until parser.eof?
	      parser.parse(visitor)
	    end
	    r.close
	    Process.waitpid(pid, 0)
	  }
	}
      end

      def mkdir(name)
	write_lock {
	  # xxx: should check name,v and Attic/name,v.
	  Dir.mkdir(@rcsdir + '/' + name)
	  return simple_dir(name)
	}
      end

=begin
--- mkfile(name, contents, log[, description[, branch_tag[, author[, date[, state[, rev]]]]]])
=end
      def mkfile(name, contents, log, description='', branch_tag=nil, author=nil, date=nil, state=nil, rev=nil)
	write_lock {
	  if branch_tag
	    h = mkfile(name, '', "file #{name} was initially added on branch #{branch_tag}.\n",
	      description, nil, author, date, 'dead')
	    h = h.file.mkbranch(h.head_rev, branch_tag, 'dead')
	    h.add(contents, log, author, date)
	    return h
	  else
	    description += "\n" if description != '' && /\n\z/ !~ description
	    state = 'Exp' if state == nil
	    rev = Revision.create("1.1") if rev == nil

	    rcs = RCS.new(description).mkrev(contents, log, author, date, state, rev)
	    f = simple_file(name, state == 'dead')
	    f.create {rcs}
	    return f.newhead(nil, nil, rev, state)
	  end
	}
      end

      # locking interfaces:
      #
      # * read_lock {...}
      # * write_lock {...}

      # for each directory, there are three states:
      #
      # * unlocked     - read_lock   -> read locked.
      #                - write_lock  -> write locked.
      # * read locked  - read_lock   -> read locked.
      #                - write_lock  -> write locked.
      # * write locked - read_lock   -> write locked.
      #                - write_lock  -> write locked.

      class LockFailure<Exception
      end

      def enable_interrupt
	trap('INT', 'DEFAULT')
	trap('TERM', 'DEFAULT')
      end

      def disable_interrupt
	if block_given?
	  begin
	    trap('INT', 'IGNORE')
	    trap('TERM', 'IGNORE')
	    yield
	  ensure
	    enable_interrupt
	  end
	else
	  trap('INT', 'IGNORE')
	  trap('TERM', 'IGNORE')
	end
      end

      def try_lock
	n = 0
	begin
	  disable_interrupt
	  yield
	rescue LockFailure
	  enable_interrupt
	  n += 1
	  if n == 10
	    STDERR.print "give up to lock #{@rcsdir}.\n"
	    raise
	  end
	  secs = 45 + rand(30)
	  STDERR.print "failed to lock #{@rcsdir} (#{n} times). wait #{secs} seconds...\n"
	  sleep secs
	  retry
	end
      end

      def mkdir_prefix(filename)
	filename = filename.clone
	if filename.sub!(/\/[^\/]*\z/, '')
	  mkdir_recursive(filename)
	end
      end

      def mkdir_recursive(filename)
	if FileTest.directory?(filename)
	  return
	end
	begin
	  Dir.mkdir(filename)
	rescue Errno::ENOENT
	  mkdir_recursive(filename.sub(/\/[^\/]*\z/, ''))
	  retry
	end
      end

      def create_lock_directory(filename)
	begin
	  mkdir_prefix(filename)
	  Dir.mkdir(filename)
	rescue Exception
	  raise LockFailure.new(filename)
	end
      end

      def delete_lock_directory(filename)
	Dir.rmdir(filename)
      end

      def create_lock_file(filename)
	begin
	  mkdir_prefix(filename)
	  File.open(filename, Fcntl::O_CREAT | Fcntl::O_EXCL | Fcntl::O_WRONLY) {}
	rescue Exception
	  raise LockFailure.new(filename)
	end
      end

      def delete_lock_file(filename)
	File.unlink(filename)
      end

      def check_read_lock
	Dir.foreach(@lockdir) {|f|
	  if /\A\#cvs\.rfl/ =~ f
	    next if $' == Info
	    raise LockFailure.new(@lockdir)
	  end
	}
      end

      def master_lock
	create_lock_directory(@master_lock_file)
	begin
	  yield
	ensure
	  delete_lock_directory(@master_lock_file)
	end
      end

      def read_lock
	return yield if @cvsroot.readonly

	if @lockstate != :unlock
	  yield
	else
	  try_lock {
	    master_lock {
	      create_lock_file(@read_lock_file)
	    }
	    @lockstate = :read_lock
	  }
	  begin
	    enable_interrupt
	    yield
	  ensure
	    disable_interrupt {
	      delete_lock_file(@read_lock_file)
	      @lockstate = :unlock
	    }
	  end
	end
      end

      def write_lock
	raise ReadOnlyMode.new('write_lock tried.') if @cvsroot.readonly

	if @lockstate == :write_lock
	  yield
	else
	  old_lock = @lockstate
	  try_lock {
	    create_lock_directory(@master_lock_file)
	    begin
	      check_read_lock
	      create_lock_file(@write_lock_file)
	    rescue LockFailure
	      delete_lock_directory(@master_lock_file)
	      raise
	    end
	    @lockstate = :write_lock
	  }
	  begin
	    yield
	  ensure
	    delete_lock_file(@write_lock_file)
	    delete_lock_directory(@master_lock_file)
	    @lockstate = old_lock
	    enable_interrupt
	  end
	end
      end
    end

    class F < R::F
      def initialize(dir, name, attic=nil)
        super(dir, name, attic)
      end

      def adjust_attic(attic=nil)
        if attic != nil
	  @attic = attic
	else
	  rcs_pathname
	end
	return @attic
      end

      def rcs_pathname(attic=nil)
	prefix = @dir.cvsroot.cvsroot + '/' + @dir.path + '/'
	suffix = @name + ',v'

	if attic != nil
	  return prefix + (attic ?  'Attic/' : '') + suffix
	elsif FileTest.exist? (result_without_attic = prefix + suffix)
	  @attic = false
	  return result_without_attic
	elsif FileTest.exist? (result_with_attic = prefix + 'Attic/' + suffix)
	  @attic = true
	  return result_with_attic
	else
	  return @attic ? result_with_attic : result_without_attic
	end
      end

      class RCSFileExist < StandardError
      end
      def create
	rcsname = rcs_pathname
	raise RCSFileExist.new(rcsname) if FileTest.exist? rcsname
	tmpname = @dir.cvsroot.cvsroot + '/' + @dir.path + '/,' + @name + ','
	rcs = yield
	File.open(tmpname, File::Constants::WRONLY |
			   File::Constants::TRUNC |
			   File::Constants::CREAT |
			   File::Constants::EXCL) {|f|
	  begin
	    rcs.dump(f)
	    rcsname = rcs_pathname(@attic = rcs.attic?)
	    dirname = File.dirname rcsname
	    Dir.mkdir(dirname, 0775) unless FileTest.directory? dirname
	    File.rename(tmpname, rcsname)
	  ensure
	    File.unlink tmpname if FileTest.exist? tmpname
	  end
	}
      end

      class NotExist < StandardError
      end
      def replace
        rcsname = rcs_pathname
	raise NotExist.new(rcsname) unless FileTest.exist? rcsname
	tmpname = @dir.cvsroot.cvsroot + '/' + @dir.path + '/,' + @name + ','
	rcs = RCS.parse(rcsname)
	yield rcs
	File.open(tmpname, File::Constants::WRONLY |
			   File::Constants::TRUNC |
			   File::Constants::CREAT |
			   File::Constants::EXCL) {|f|
	  begin
	    rcs.dump(f)
	    newrcsname = rcs_pathname(@attic = rcs.attic?)
	    File.rename(tmpname, newrcsname)
	    File.unlink(rcsname) if newrcsname != rcsname
	  ensure
	    File.unlink tmpname if FileTest.exist? tmpname
	  end
	}
      end

      def parse
        rcsname = rcs_pathname
	raise NotExist.new(rcsname) unless FileTest.exist? rcsname
	return RCS.parse(rcsname)
      end

      def parse_raw_log(visitor, opts=[])
	@dir.read_lock {
	  @dir.with_work {|t|
	    r, w = IO.pipe
	    pid = fork {
	      STDOUT.reopen(w)
	      File.open('/dev/null', 'w') {|f| STDERR.reopen(f)}
	      r.close
	      w.close
	      Dir.chdir(t.path)
	      command = ['rlog']
	      command += opts
	      command << rcs_pathname
	      exec *command
	    }
	    w.close
	    res = Parser::Log.new(r).parse(visitor)
	    r.close
	    Process.waitpid(pid, 0)
	    return res
	  }
	}
      end

      def parse_log(visitor, opts=[])
        @dir.read_lock {
	  rcs = parse
	  visitor.rcsfile(rcs_pathname)
	  visitor.rcsfile_splitted(@dir.cvsroot.cvsroot + '/' + @dir.path, @name, @attic)
	  #visitor.working_file(...)
	  visitor.head(rcs.head)
	  visitor.branch(rcs.branch)
	  #visitor.lock_strict if rcs.admin_phrase.include? :strict
	  #rcs.locks.each {|user, rev| visitor.lock(user, rev)}
	  #visitor.access(rcs.admin_phrase[:access]...)
	  rcs.symbols.each {|sym, rev| visitor.symbol(sym, rev)}
	  #visitor.total_revisions(...)
	  #visitor.selected_revisions(...)
	  visitor.delta_finished
	  visitor.description(rcs.desc)
	  rcs.each_delta {|d|
	    visitor.delta_without_next(d.rev, d.date, d.author, d.state, d.branches)
	    visitor.delta(d.rev, d.date, d.author, d.state, d.branches, d.nextrev)
	    visitor.deltatext_log(d.rev, d.log)
	    visitor.deltatext(d.rev, d.log, d.text)
	  }
	  visitor.finished(nil)
	}
      end

      def parse_rcs(visitor)
        parse_raw_rcs(Parser::RCS::RCSVisitor.new(visitor))
      end

      def parse_raw_rcs(visitor)
	@dir.read_lock {
	  File.open(rcs_pathname) {|r|
	    Parser::RCS.new(r).parse(visitor)
	  }
	}
      end

      def mode
	@dir.read_lock {
	  s = File.stat(rcs_pathname)
	  modes = ['', 'x', 'w', 'wx', 'r', 'rx', 'rw', 'rwx']
	  m = s.mode & 0555 
	  # Since RCS files doesn't record a `write' permission,
	  # we assume it is identical to the corresponding `read' permission.
	  m |= (s.mode & 0444) >> 1
	  return 'u=' + modes[(m & 0700) >> 6] +
		',g=' + modes[(m & 0070) >> 3] +
		',o=' + modes[(m & 0007)]
        }
      end

      def checkout(rev) 
	contents = mtime = m = nil
	@dir.read_lock {
	  contents, mtime = RCS.parse(rcs_pathname).checkout(rev)
	  m = mode
	}
	yield contents, Attr.new(mtime, m)
      end

      def annotate(rev)
        fullannotate(rev, nil) {|line, date1, rev1, author, rev2, date2|
	  yield line, date1, rev1, author
	}
      end

=begin
--- fullannotate(rev[, branch]) {|line, date1, rev1, author, rev2, date2| ...}
=end
      def fullannotate(rev, branch=nil, &block)
	unless branch
	  branch = rev.branch unless rev.on_trunk?
	end

	v = FullAnnotateVisitor.new(rev, branch, &block)
	parse_rcs(DeltaFilter.new(v) {
	  |diffroot, difftree, editroot, edittree, editleaf|
	  trunk_revs = []
	  branch_revs = []

	  r = editroot
	  while r
	    trunk_revs << r
	    r = difftree[r]
	  end

	  if branch
	    r = nil
	    editleaf.each_key {|r|
	      break if r.branch == branch
	    }
	    r = branch.origin unless r
	    while !r.on_trunk?
	      branch_revs << r
	      r = difftree[r]
	    end
	    branch_revs << r

	    v.trunk_branch = r

	    unless branch_revs.include?(rev) || (rev < r && trunk_revs.include?(rev))
	      raise ArgumentError.new("#{rev.to_s} is not exist between #{editroot} to #{branch_revs[0].to_s}")
	    end
	  else
	    unless trunk_revs.include?(rev)
	      raise ArgumentError.new("#{rev.to_s} is not exist between #{editroot} to #{trunk_revs[-1].to_s}")
	    end

	    v.trunk_branch = rev
	  end

	  v.trunk_revs = trunk_revs
	  v.branch_revs = branch_revs
	  v.minrev = editroot
	  v.maxrev = branch ? branch_revs[0] : diffroot
	  v.difftree = difftree
	  v.editroot = editroot

	  revs = {}
	  trunk_revs.each {|r| revs[r] = true}
	  branch_revs.each {|r| revs[r] = true}
	  revs
	})
      end

      class FullAnnotateVisitor
        def initialize(rev, branch, &block)
	  @rev = rev
	  @branch = branch
	  @block = block
	  @trunk_text = nil
	  @branch_text = nil
	  @target_text = nil
	  @date = {}
	  @author = {}
	end
	attr_accessor :trunk_revs, :branch_revs, :minrev, :maxrev, :trunk_branch, :difftree, :editroot

        def delta(rev, date, author, state, branch, nextrev)
	  @date[rev] = date
	  @author[rev] = author
	end

        def deltatext(rev, log, text)
	  if !@trunk_revs.empty? && @trunk_revs[-1] == rev
	    @trunk_revs.pop
	    unless @trunk_text
	      @trunk_text = RCSText.new(text,
	        lambda {|line| Line.new(line)})
	    else
	      # delta from rev0 to rev.
	      rev0 = @difftree[rev]
	      @trunk_text.patch!(text,
	        lambda {|line| # this line is exist until rev.
		  line = Line.new(line)
		  unless @branch
		    if @trunk_branch <= rev
		      line.rev2 = rev
		      line.date2 = @date[rev0]
		    end
		  end
		  line
		},
		lambda {|line| # this line is exist since rev0.
		  if line
		    unless @trunk_branch <= rev
		      line.rev1 = rev0
		      line.date1 = @date[rev0]
		    end
		  end
		})
	    end
	  end

	  if !@branch_revs.empty? && @branch_revs[-1] == rev
	    @branch_revs.pop
	    unless @branch_text
	      @branch_text = @trunk_text.dup
	    else
	      # delta from rev0 to rev.
	      rev0 = @difftree[rev]
	      @branch_text.patch!(text,
	        lambda {|line| # this line is exist since rev.
		  if @rev <= rev0
		    false
		  else
		    line = Line.new(line)
		    line.rev1 = rev
		    line.date1 = @date[rev]
		    line
		  end
		},
	        lambda {|line| # this line is exist until rev0.
		  if line
		    if @rev <= rev0
		      line.rev2 = rev0
		      line.date2 = @date[rev]
		    end
		  end
		})
	    end
	  end

	  if rev == @rev
	    if rev.on_trunk?
	      @target_text = @trunk_text.dup
	    else
	      @target_text = @branch_text.dup
	    end
	  end
	end

        def finished
	  @target_text.lines.each {|line|
	    if line.rev1 == nil
	      line.rev1 = @minrev
	      line.date1 = @date[@editroot]
	    end
	    if line.rev2 == nil
	      line.rev2 = @maxrev
	      line.date2 = false
	    end
	  }
	  @target_text.lines.each {|line|
	    @block.call(line.line, line.date1, line.rev1, @author[line.rev1], line.rev2, line.date2)
	  }
	end

	class Line
	  def initialize(line)
	    @line = line
	    @rev1 = nil
	    @rev2 = nil
	    @date1 = nil
	    @date2 = nil
	  end
	  attr_reader :line
	  attr_accessor :rev1, :rev2, :date1, :date2
	end
      end

      class DeltaFilter < Visitor
        def initialize(visitor, &filter)
	  @visitor = visitor
	  @filter = filter
	  @difftree = {}
	  @diffroot = nil
	  @edittree = {}
	  @editroot = nil
	  @editleaf = {}
	end

	def head(rev)
	  @diffroot = rev
	  @editleaf[rev] = true
	end

        def delta(rev, date, author, state, branch, nextrev)
	  @visitor.delta(rev, date, author, state, branch, nextrev)

	  if nextrev
	    @difftree[nextrev] = rev if nextrev
	    if rev.on_trunk?
	      @edittree[rev] = nextrev
	    else
	      @edittree[nextrev] = rev
	    end
	  else
	    if rev.on_trunk?
	      @editroot = rev
	    else
	      @editleaf[rev] = true
	    end
	  end

	  branch.each {|r|
	    @difftree[r] = rev
	    @edittree[r] = rev
	  }
	end

	def delta_finished
	  @revs = @filter.call(@diffroot, @difftree, @editroot, @edittree, @editleaf)
	end

        def deltatext(rev, log, text)
	  @visitor.deltatext(rev, log, text) if @revs.include? rev
	end

	def finished
	  return @visitor.finished
	end
      end

      class TagExist < StandardError
      end
      def mkbranch(rev, tag, state=nil)
	@dir.write_lock {
	  branch_rev = nil
	  replace {|rcs|
	    nums = {}
	    rcs.symbols.each {|t, r|
	      raise TagExist.new(tag) if t == tag
	      if r.branch? && r.origin == rev
		n = r.arr[-1]
		nums[n] = n
	      end
	    }
	    rcs.each_delta {|d|
	      state = d.state if d.rev == rev
	    }

	    i = 2
	    while nums.include? i
	      i += 2
	    end
	    branch_rev = Revision.create(rev.arr + [0, i])
	    rcs.symbols << [tag, branch_rev]
	  }
	  return newhead(tag, branch_rev, rev, state)
	}
      end

      def heads
	return parse_log(HeadsVisitor.new(self, Head))
      end

      def newhead(branch_tag, branch_rev, head_rev, state, default_branch_head=nil)
        return Head.new(self, branch_tag, branch_rev, head_rev, state, default_branch_head)
      end
      class Head < R::F::Head
        def initialize(file, branch_tag, branch_rev, head_rev, state, default_branch_head=nil)
	  super(file, branch_tag, branch_rev, head_rev, state, default_branch_head)
	end

=begin
--- add(contents, log[, author[, date]])
=end
        def add(contents, log, author=nil, date=nil)
	  raise AlreadyExist.new("already exist: #{@file.inspect}:#{@head_rev}") if @state != 'dead'
	  return mkrev(contents, log, author, date, 'Exp')
	end

=begin
--- checkin(contents, log[, author[, date]])
=end
	def checkin(contents, log, author=nil, date=nil)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  return mkrev(contents, log, author, date, 'Exp')
	end

=begin
--- remove(log[, author[, date]])
=end
	def remove(log, author=nil, date=nil)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  contents = @file.checkout(@head_rev) {|c, a| c}
	  return mkrev(contents, log, author, date, 'dead')
	end

	def mkrev(contents, log, author=nil, date=nil, state=nil)
	  state = 'Exp' if state == nil
	  @file.dir.write_lock {
	    @file.replace {|rcs|
	      rcs.mkrev(contents, log, author, date, state, next_rev)
	      if @default_branch_head
		rcs.branch = nil
		@default_branch_head = nil
	      end
	    }
	    if @branch_tag == nil && @head_rev.on_trunk?
	      attic = state == 'dead'
	      @file.adjust_attic(attic)
	    end
	  }
	  @head_rev = next_rev
	  @state = state
	  return @head_rev
	end
      end
    end
  end
end
