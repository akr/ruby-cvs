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

	    rcs = RCS.new
	    rcs.desc = description
	    rcs.mkrev(contents, log, author, date, state, rev)
	    f = simple_file(name, state == 'dead')
	    f.open(:replace) {|out| rcs.dump(out)}
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

      def open(mode)
        case mode
	when :replace
	  rcsname = rcs_pathname
	  tmpname = @dir.cvsroot.cvsroot + '/' + @dir.path + '/,' + @name + ','
	  File.open(tmpname, File::Constants::WRONLY | File::Constants::CREAT | File::Constants::EXCL) {|f|
	    begin
	      yield f
	      File.rename(tmpname, rcsname)
	    ensure
	      File.unlink tmpname if FileTest.exist? tmpname
	    end
	  }
	else
	  raise ArgumentError.new("invalid access mode #{mode.inspect}")
	end
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

      def checkout_ext(rev) # deplicated.
	t = TempDir.create
	pid = fork {
	  File.open('/dev/null', 'w') {|f| STDOUT.reopen(f)}
	  File.open('/dev/null', 'w') {|f| STDERR.reopen(f)}
	  Dir.chdir(t.path)
	  command = ['co', '-ko', '-M']
	  command << '-r' + rev.to_s
	  command << rcs_pathname
	  File.umask(0)
	  exec *command
	}
	Process.waitpid(pid, 0)
	raise CheckOutCommandFailure.new($?) if $? != 0
	yield t.open(@name) {|f| [f.read, Attr.new(f.stat.mtime.gmtime, mode)]}
      end

      def checkout(rev) 
	contents = mtime = m = nil
	@dir.read_lock {
	  contents, mtime = RCS.parse(rcs_pathname).checkout(rev)
	  m = mode
	}
	yield contents, Attr.new(mtime, m)
      end

      class CheckInCommandFailure < StandardError
	def initialize(status)
	  super("status: #{status}")
	end
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

      def mkbranch(rev, tag, state=nil)
	@dir.write_lock {
	  nums = {}
	  i, state = parse_log(MkBranchVisitor.new(rev, tag, state), state ? ['-h'] : [])

	  branch_rev = Revision.create(rev.arr + [0, i])
	  command = ['rcs']
	  command << "-q"
	  command << "-n#{tag}:#{branch_rev.to_s}"
	  command << rcs_pathname
	  system *command
	  return newhead(tag, branch_rev, rev, state)
	}
      end

      class MkBranchVisitor < Visitor
	def initialize(rev, tag, state)
	  @rev = rev
	  @tag = tag
	  @state = state
	  @nums = {}
	end

        def symbol(tag, rev)
	  if rev.branch? && rev.origin == @rev
	    n = rev.arr[-1]
	    @nums[n] = n
	  end
	end

	def delta_rlog(rev, locked_by, date, author, state, add, del, branches, message)
	  if rev == @rev
	    @state = state
	  end
	end

	def finished(buf)
	  i = 2
	  while @nums.include? i
	    i += 2
	  end
	  return i, @state
	end
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

	def rcs_lock(rev)
	  command = ['rcs', '-q', "-l#{rev}", @file.rcs_pathname]
	  system *command
	  raise RCSLockCommandFailure.new($?) if $? != 0
	end
	class RCSLockCommandFailure < StandardError
	  def initialize(status)
	    super("status: #{status}")
	  end
	end

	def run_ci(contents, log, desc, state, author, date)
	  @work = TempDir.create unless @work
	  basename = @file.name
	  @work.open(basename, 'w') {|f| f.print contents}

	  @file.dir.write_lock {
	    rcsfile = @file.rcs_pathname

	    unless @branch_tag && @branch_rev.origin == @head_rev
	      rcs_lock @head_rev
	    end
	    pid = fork {
	      command = ['ci',
		'-f',
		"-q#{next_rev}",
		'-m' + (/\A\s*\z/ =~ log ? '*** empty log message ***' : log),
		"-t-#{desc}",
		"-s#{state}",
	      ]
	      command << "-w#{author}" if author
	      command << "-d#{date}" if date
	      command += [
		rcsfile, 
		@work.path(basename)
	      ]
	      exec *command
	    }
	    Process.waitpid(pid, 0)
	    raise CheckInCommandFailure.new($?) if $? != 0

	    if @default_branch_head
	      pid = fork {
		command = ['rcs',
		  '-q',
		  '-b',
		  rcsfile
		]
		exec *command
	      }
	      Process.waitpid(pid, 0)
	      raise RCSCommandFailure.new($?) if $? != 0
	      @default_branch_head = nil
	    end

	    if @branch_tag == nil && @head_rev.on_trunk?
	      attic = state == 'dead'
	      newrcsfile = @file.rcs_pathname(attic)
	      if newrcsfile != rcsfile
		dir = @file.dir.cvsroot.cvsroot + '/' + @file.dir.path
	        if attic && ! FileTest.directory?(dir + '/Attic')
		  Dir.mkdir(dir + '/Attic', 0775)
		end
		File.rename(rcsfile, newrcsfile)
		@file.adjust_attic(attic)
	      end
	    end
	  }
	end
	class CheckInCommandFailure < StandardError
	  def initialize(status)
	    super("status: #{status}")
	  end
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
	  run_ci(contents, log, '', state, author, date)
	  @head_rev = next_rev
	  @state = state
	  return @head_rev
	end
      end
    end
  end
end
