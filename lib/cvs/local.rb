require 'fcntl'
require 'socket' # to use gethostname

class CVS
  class L < R # local repository
    def initialize(cvsroot)
      super(cvsroot)
    end

    def top_dir
      return D.new(self, '.')
    end

    class D < R::D
      Info = ".#{Socket.gethostname}.#{$$}"

      def initialize(cvsroot, path)
        super(cvsroot, path)

	@rcsdir = @cvsroot.cvsroot + '/' + @path

	# xxx: "#{@cvsroot.cvsroot}/CVSROOT/config" should be examined.
	@lockdir = @rcsdir
	@master_lock_file = "#{@lockdir}/\#cvs.lock"
	@read_lock_file = "#{@lockdir}/\#cvs.rfl#{Info}"
	@write_lock_file = "#{@lockdir}/\#cvs.wfl#{Info}"
	@lockstate = :unlock
      end

      def simple_dir(name)
	return D.new(@cvsroot, @path + '/' + name)
      end

      def simple_file(name, attic=nil)
	return F.new(self, name, attic)
      end

      def listdir
	res = []
	dir = @rcsdir
        Dir.foreach(dir) {|name|
	  next if /\A(\.|\.\.|CVS|Attic)\z/ =~ name
	  if FileTest.directory?(dir + '/' + name)
	    res << simple_dir(name)
	  end
	}
	return res
      end

      def listfile
	res = []
	dir = @rcsdir
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
	return res
      end

      def parse_raw_log(visitor, opts=[])
	rcs_pathnames = listfile.collect {|f| f.rcs_pathname}
	return if rcs_pathnames.empty?
	with_work {|t|
	  r, w = IO.pipe
	  pid = fork {
	    STDOUT.reopen(w)
	    open('/dev/null', 'w') {|f| STDERR.reopen(f)}
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
	if attic == nil
	  if FileTest.exist?(rcs_pathname)
	    @attic = false
	  elsif FileTest.exist?(rcs_pathname(true))
	    @attic = true
	  end
	end
      end

      def rcs_pathname(attic=nil)
	attic = @attic if attic == nil
	return @dir.cvsroot.cvsroot + '/' + @dir.path + (attic ? '/Attic/' : '/') + @name + ',v'
      end

      def parse_raw_log(visitor, opts=[])
	@dir.with_work {|t|
	  r, w = IO.pipe
	  pid = fork {
	    STDOUT.reopen(w)
	    open('/dev/null', 'w') {|f| STDERR.reopen(f)}
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
      end

      def parse_rcs(visitor)
        parse_raw_rcs(Parser::RCS::RCSVisitor.new(visitor))
      end

      def parse_raw_rcs(visitor)
        open(rcs_pathname) {|r|
	  Parser::RCS.new(r).parse(visitor)
	}
      end

      def mode
	s = File.stat(rcs_pathname)
	modes = ['', 'x', 'w', 'wx', 'r', 'rx', 'rw', 'rwx']
	m = s.mode & 0555 
	# Since RCS files doesn't record a `write' permission,
	# we assume it is identical to the corresponding `read' permission.
	m |= (s.mode & 0444) >> 1
	return 'u=' + modes[(m & 0700) >> 6] +
	      ',g=' + modes[(m & 0070) >> 3] +
	      ',o=' + modes[(m & 0007)]
      end

      def checkout(rev)
	t = TempDir.create
	pid = fork {
	  open('/dev/null', 'w') {|f| STDOUT.reopen(f)}
	  open('/dev/null', 'w') {|f| STDERR.reopen(f)}
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
      class CheckInCommandFailure < StandardError
	def initialize(status)
	  super("status: #{status}")
	end
      end

      def checkout2(rev)
	time, contents = parse_rcs(DeltaVisitor.new(rev, Checkout2Visitor.new(rev)))
	yield contents, Attr.new(time, mode)
      end

      class Checkout2Visitor < Visitor
	def initialize(rev)
	  @rev = rev
	  @text = nil
	end

        def delta(phase, rev, date, author, state, branch, nextrev)
	  if rev == @rev
	    @date = date
	    @author = author
	    @state = state
	  end
	end

        def deltatext(phase, rev, log, text)
	  case phase
	  when :trunk_after
	    if @text == nil
	      @text = RCSText.new(text)
	    else
	      @text = @text.patch(text)
	    end
	  when :branch_before
	    @text = @text.patch(text)
	  end
	end

	def finished
	  return @date, @text.to_s
	end
      end

      def annotate(rev, &block)
	parse_rcs(DeltaVisitor.new(rev, AnnotateVisitor.new(rev)))
      end

      class AnnotateVisitor < Visitor
	def initialize(target)
	  @target = target
	  @minrev = nil
	  @maxrev = nil
	  @diffsrc = {}
	  @trunk_text = nil
	  @branch_text = nil
	  @target_text = nil
	end

        def delta(phase, rev, date, author, state, branch, nextrev)
	  #p [phase, rev.to_s, date, author, state, branch.collect {|r| r.to_s}, nextrev.to_s]
	  @diffsrc[nextrev] = rev if nextrev
	  branch.each {|r| @diffsrc[r] = rev}
	  @minrev = rev if !@minrev || rev < @minrev
	  @maxrev = rev if !@maxrev || @maxrev < rev
	end

        def deltatext(phase, rev, log, text)
	  #p [phase, rev.to_s, log, text]
	  case phase
	  when :trunk_after
	    if @trunk_text == nil
	      @trunk_text = RCSText.new(text,
	        lambda {|line|
		  line = Line.new(line)
		  line.rev2 = rev if @target.on_trunk?
		  line
		})
	    else
	      @trunk_text.patch!(text,
	        lambda {|line|
		  line = Line.new(line)
		  line.rev2 = rev if @target.on_trunk?
		  line
		},
		lambda {|line| line.rev1 = @diffsrc[rev]})
	    end
	  when :trunk_before
	    @branch_text = @trunk_text.dup unless @branch_text
	    @trunk_text.patch!(text,
	      lambda {|line| false},
	      lambda {|line| line.rev1 = @diffsrc[rev] if line})
	  when :branch_before
	    @branch_text = @trunk_text.dup unless @branch_text
	    @branch_text.patch!(text,
	      lambda {|line|
	        line = Line.new(line)
		line.rev1 = rev
		line
	      },
	      lambda {|line| line.rev2 = @diffsrc[rev]})
	  when :branch_after
	    @branch_text.patch!(text,
	      lambda {|line| false},
	      lambda {|line| line.rev2 = @diffsrc[rev] if line})
	  end
	  if rev == @target
	    if @target.on_trunk?
	      @target_text = @trunk_text.dup
	    else
	      @target_text = @branch_text.dup
	    end
	  end
	end

	def finished
	  unless @target_text
	    @target_text = @target.on_trunk? ? @trunk_text : @branch_text
	  end
	  @target_text.lines.each {|line|
	    line.rev1 = @minrev if line.rev1 == nil
	    line.rev2 = @maxrev if line.rev2 == nil
	  }
	  # xxxx
	  @target_text.lines.each {|l|
	    print "#{l.rev1.to_s}-#{l.rev2.to_s} #{l.line}"
	  }
	end

	class Line
	  def initialize(line)
	    @line = line
	    @rev1 = nil
	    @rev2 = nil
	  end
	  attr_reader :line
	  attr_accessor :rev1, :rev2
	end
      end

      class RCSText
        def initialize(text, annotate=nil)
	  text = split(text) if String === text
	  text.collect! {|line| annotate.call(line)} if annotate
	  @text = text
	end

	def lines
	  return @text
	end

	def to_s
	  return @text.join('')
	end

	def split(str)
	  a = []
	  str.each_line("\n") {|l| a << l}
	  return a
	end

	def patch!(diff, annotate_add=nil, annotate_del=nil)
	  diff = split(diff) if String === diff
	  text = @text.dup
	  text.unshift(nil) # adjust array index as line number.
	  i = 0
	  while i < diff.length
	    case diff[i]
	    when /\Aa(\d+)\s+(\d+)/
	      beg = $1.to_i
	      len = $2.to_i
	      adds = diff[i+1,len]
	      adds.collect! {|line| annotate_add.call(line)} if annotate_add
	      text[beg] = [text[beg], adds]
	      i += len + 1
	    when /\Ad(\d+)\s+(\d+)/
	      beg = $1.to_i
	      len = $2.to_i
	      text[beg, len].each {|line| annotate_del.call(line)} if annotate_del
	      text.fill(nil, beg, len)
	      i += 1
	    else
	      raise InvalidDiffFormat.new(diff[i])
	    end
	  end
	  text.flatten!
	  text.compact!
	  @text = text
	  return self
	end

	def patch(diff, annotate_add=nil, annotate_del=nil)
	  return self.dup.patch!(diff, annotate_add, annotate_del)
	end

	class InvalidDiffFormat < StandardError
	end
      end

      class DeltaVisitor < Visitor
        def initialize(target, visitor)
	  @visitor = visitor
	  @target = target
	  @target_branch = target.branch

	  @branch = []
	  @origin = []
	  until target.on_trunk?
	    @origin << target
	    @branch << target.branch
	    target = target.origin
	  end

	  @trunk_target = target

	  @track_trunk_after = true
	  @track_trunk_before = false
	  @track_branch_after = false
	  @track_branch_before = false
	  @branch_level = @branch.length - 1
	end

	def delta(rev, *args)
	  track_delta(rev, :delta, args)
	end

	def delta_finished
	  @track_trunk_after = true
	  @track_trunk_before = false
	  @track_branch_after = false
	  @track_branch_before = false
	  @branch_level = @branch.length - 1
	  @visitor.delta_finished
	end

	def finished
	  return @visitor.finished
	end

	def deltatext(rev, *args)
	  track_delta(rev, :deltatext, args)
	end

	def track_delta(rev, meth, args)
	  if @track_branch_after
	    if rev.on?(@target_branch)
	      @visitor.send(meth, :branch_after, rev, *args)
	    end
	  end

	  if @track_branch_before
	    if rev.on?(@branch[@branch_level])
	      @visitor.send(meth, :branch_before, rev, *args)
	      if rev == @origin[@branch_level]
		@branch_level -= 1
		if @branch_level < 0
		  @track_branch_before = false
		  @track_branch_after = true
		end
	      end
	    end
	  end

	  if @track_trunk_before
	    if rev.on_trunk?
	      @visitor.send(meth, :trunk_before, rev, *args)
	    end
	  end

	  if @track_trunk_after
	    if rev.on_trunk?
	      @visitor.send(meth, :trunk_after, rev, *args)
	      if rev == @trunk_target
	        @track_trunk_after = false
	        @track_trunk_before = true
		@track_branch_before = true if !@branch.empty?
	      end
	    end
	  end
	end
      end

      def heads
	return parse_log(HeadsVisitor.new(self, Head))
      end

      class Head < R::F::Head
        def initialize(file, branch_tag, branch_rev, head_rev, state)
	  super(file, branch_tag, branch_rev, head_rev, state)
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
	  rcsfile = @file.rcs_pathname
	  basename = File.basename(rcsfile, ',v')
	  @work.open(basename, 'w') {|f| f.print contents}

	  @file.dir.write_lock {
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
	  }
	end
	class CheckInCommandFailure < StandardError
	  def initialize(status)
	    super("status: #{status}")
	  end
	end

        def add(contents, log, author=nil, date=nil)
	  raise AlreadyExist.new("already exist: #{@file.inspect}:#{@head_rev}") if @state != 'dead'
	  run_ci(contents, log, '', 'Exp', author, date)
	  return @head_rev = next_rev
	end

	def checkin(contents, log, author=nil, date=nil)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  run_ci(contents, log, '', 'Exp', author, date)
	  return @head_rev = next_rev
	end

	def remove(log, author=nil, date=nil)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  contents = @file.checkout(@head_rev) {|f, a| f.read}
	  run_ci(contents, log, '', 'dead', author, date)
	  return @head_rev = next_rev
	end
      end
    end
  end
end
