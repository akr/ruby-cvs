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

      def parse_log(visitor, opts=[])
        listfile.each {|f|
	  f.parse_log(visitor, opts)
	}
      end

      def parse_raw_log(visitor, opts=[])
	raise NotImplementedError.new
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
	    rev = RCS::Revision.create("1.1") if rev == nil

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
	elsif FileTest.exist?(result_without_attic = prefix + suffix)
	  @attic = false
	  return result_without_attic
	elsif FileTest.exist?(result_with_attic = prefix + 'Attic/' + suffix)
	  @attic = true
	  return result_with_attic
	else
	  return @attic ? result_with_attic : result_without_attic
	end
      end

      class RCSFileExist < StandardError
      end
      def create
	rcs = yield
	@attic = rcs.attic?
	rcsname = rcs_pathname(@attic)
	dirname = File.dirname rcsname
	Dir.mkdir(dirname, 0775) unless FileTest.directory? dirname
	RCS.create(rcsname) {rcs}
      end

      def update
        rcsname = rcs_pathname
	RCS.update(rcsname) {|rcs|
	  yield rcs
	  @attic = rcs.attic?
	}
	newrcsname = rcs_pathname(@attic)
	if rcsname != newrcsname
	  dirname = File.dirname newrcsname
	  Dir.mkdir(dirname, 0775) unless FileTest.directory? dirname
	  File.rename(rcsname, newrcsname)
	end
      end

      def parse
        rcsname = rcs_pathname
	return RCS.parse(rcsname)
      end

      def parse_raw_log(visitor, opts=[])
	raise NotImplementedError.new
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
	    if r = d.rev.on_trunk? ? d.nextrev : d.rev
	      add = 0
	      del = 0
	      RCS::Text.parse_diff(rcs[r].text) {|mark, beg, len, addlines|
		if mark == :del
		  del += len
		else
		  add += len
		end
	      }
	      if d.rev.on_trunk?
	        tmp = add
		add = del
		del = tmp
	      end
	    else
	      add = nil
	      del = nil
	    end
	    visitor.delta_rlog(d.rev, nil, d.date, d.author, d.state, add, del, d.branches, d.log)
	    visitor.delta_without_next(d.rev, d.date, d.author, d.state, d.branches)
	    visitor.delta(d.rev, d.date, d.author, d.state, d.branches, d.nextrev)
	    visitor.deltatext_log(d.rev, d.log)
	    visitor.deltatext(d.rev, d.log, d.text)
	  }
	  visitor.finished(nil)
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
	rcs = @dir.read_lock {RCS.parse(rcs_pathname)}
	rcs.annotate(rev, branch, &block) 
      end

      class TagExist < StandardError
      end
      def mkbranch(rev, tag, state=nil)
	@dir.write_lock {
	  branch_rev = nil
	  update {|rcs|
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
	    branch_rev = RCS::Revision.create(rev.arr + [0, i])
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
	    @file.update {|rcs|
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
