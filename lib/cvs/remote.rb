require 'fcntl'
require 'delegate'

class CVS
  class R < CVS # remote repository
    def initialize(cvsroot, readonly=false)
      @cvsroot = cvsroot
      @readonly = readonly
    end
    attr_accessor :cvsroot, :readonly

    def top_dir
      return D.new(self, nil, '.')
    end

    class WorkDir < DelegateClass(TempDir)
      def initialize(dir)
	@dir = dir
	super(TempDir.create)
	self.mkdir('CVS')
	self.open('CVS/Root', 'w') {|f| f.print "#{@dir.cvsroot.cvsroot}\n"}
	self.open('CVS/Repository', 'w') {|f| f.print "#{@dir.path}\n"}
        @entries = {}
	update_entries
      end
      attr_reader :entries

      def update_entries
	self.open('CVS/Entries', 'w') {|f|
	  @entries.each {|k, v| f.print "/#{k}/#{v}\n"}
	  f.print "D\n"
	}
      end
    end

    class D < CVS::D
      def initialize(cvsroot, parent, path)
	@cvsroot = cvsroot
	@parent = parent
	@path = path.sub(/\A\.\//, '')
	@entries = {}
      end
      attr_reader :cvsroot, :path, :entries

      def with_work
	unless @work
	  @work = WorkDir.new(self)
	end
	yield @work
      end

      def run_cvs_may_error(args, out='/dev/null', err='/dev/null', env=[], setup_proc=nil, conc_proc=nil)
	command = ['cvs', '-f', '-d', @cvsroot.cvsroot]
	command += args
	with_work {|wd|
	  setup_proc.call(wd) if setup_proc
	  pid = fork {
	    env.each {|k, v| ENV[k] = v}
	    if IO === out
	      STDOUT.reopen(out)
	    else
	      open(out, "w") {|f| STDOUT.reopen(f)}
	    end
	    if IO === err
	      STDERR.reopen(err)
	    else
	      open(err, "w") {|f| STDERR.reopen(f)}
	    end
	    Dir.chdir(wd.path)
	    exec(*command)
	  }
	  conc_proc.call(wd) if conc_proc
	  Process.waitpid(pid, nil)
	  yield wd, $? if block_given?
	}
      end

      def run_cvs(args, out='/dev/null', err='/dev/null', env=[], setup_proc=nil, conc_proc=nil)
        run_cvs_may_error(args, out, err, env, setup_proc, conc_proc) {|wd, status|
	  raise CVSCommandFailure.new(status) if status != 0
	  yield wd if block_given?
	}
      end
      class CVSCommandFailure < StandardError
        def initialize(status)
	  super("status: #{status}")
	end
      end

      def top?
        return @parent == nil
      end

      def parent
	return @parent
      end

      # Maybe `create_dir' is better name because it is a factory method.
      # But it is confusing to a function which create directory in the repository.
      def simple_dir(name)
	return D.new(@cvsroot, self, @path + '/' + name)
      end

      def simple_file(name, attic=nil)
	return F.new(self, name, attic)
      end

      def listdir
	res = []
	r, w = IO.pipe
	r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
        run_cvs(['update', '-r00', '-d', '-p'], '/dev/null', w, [], nil, lambda {
	  w.close
	  while line = r.gets
	    if / server: New directory `(.*)' -- ignored\n\z/ =~ line
	      res << dir($1)
	    end
	  end
	  r.close
	})
	return res
      end

      def listfile
	res = []
	r, w = IO.pipe
	r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
        run_cvs(['log', '-R'], w, '/dev/null', [], nil, lambda {
	  w.close
	  res = []
	  while line = r.gets
	    if /\/(Attic\/)?([^\/]*),v\n\z/ =~ line
	      res << file($2, $1 != nil)
	    end
	  end
	  r.close
	})
	return res
      end

      def parse_log(visitor, opts=[])
        parse_raw_log(Parser::Log::LogVisitor.new(visitor), opts)
      end

      def parse_raw_log(visitor, opts=[])
	r, w = IO.pipe
	r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
        run_cvs(['log', *opts], w, '/dev/null', [], nil, lambda {
	  w.close
	  parser = Parser::Log.new(r)
	  until parser.eof?
	    parser.parse(visitor)
	  end
	  r.close
	})
      end

      def mkdir(name)
	run_cvs(['add', name], '/dev/null', '/dev/null', [], lambda {|wd|
	  wd.mkdir(name)
	})
	return simple_dir(name)
      end

      def mkfile(name, contents, log, description='', branch_tag=nil)
	# `description' is ignored with a remote repository because
	# `cvs commit' doesn't send CVS/xxx,t to the server.  It is
	# possible to send the description to the server if `add' and
	# `commit' request is sent on SINGLE connection.  But it is
	# impossible with cvs COMMAND and it requires to talk CVS
	# client/server protocol directly.
	newrev = nil
	r, w = IO.pipe
	r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
	run_cvs(['commit', '-f', '-m', log, name], w, '/dev/null', [],
	  lambda {|wd|
	    wd.open("CVS/#{name},t", 'w') {|f| f.print(description)}
	    wd.open(name, 'w') {|f| f.print(contents)}
	    wd.entries[name] = "0//-ko/#{branch_tag && ('T' + branch_tag)}"
	    wd.update_entries
	  },
	  lambda {|wd|
	    w.close
	    while line = r.gets
	      if /^initial revision: ([0-9.]+)$/ =~ line
		newrev = Revision.create($1)
	      elsif /^new revision: ([0-9.]+); previous revision: [0-9.]+$/ =~ line
		newrev = Revision.create($1)
	      end
	    end
	    r.close
	  })
	return simple_file(name, branch_tag != nil).newhead(branch_tag, newrev.branch, newrev, 'Exp')
      end

      def to_s
	return "<#{self.class} #{@cvsroot.cvsroot}//#{@path}>"
      end

      def inspect
	return self.to_s
      end
    end

    class F < CVS::F
      def initialize(dir, name, attic=nil)
	@dir = dir
	@name = name
	@attic = attic
      end
      attr_reader :dir, :name, :attic

      def parse_log(visitor, opts=[])
        return parse_raw_log(Parser::Log::LogVisitor.new(visitor), opts)
      end

      def parse_raw_log(visitor, opts=[])
	res = nil
	r, w = IO.pipe
	r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
        @dir.run_cvs(['log'] + opts + [@name], w, '/dev/null', [], nil, lambda {
	  w.close
	  res = Parser::Log.new(r).parse(visitor)
	  r.close
	})
	return res
      end

      def tags
	return parse_log(TagsVisitor.new, ['-h'])
      end

      class TagsVisitor < Visitor
	def initialize
	  @tags = {}
	end

        def symbol(tag, rev)
	  @tags[tag] = rev
	end

	def finished(buf)
	  return @tags
	end
      end

      def checkout(rev)
        @dir.run_cvs(['update', '-ko', '-r' + rev.to_s, @name]) {|wd|
	  s = File.stat(wd.path(@name))
	  modes = ['', 'x', 'w', 'wx', 'r', 'rx', 'rw', 'rwx']
	  mode = 'u=' + modes[(s.mode & 0700) >> 6] +
	        ',g=' + modes[(s.mode & 0070) >> 3] +
	        ',o=' + modes[(s.mode & 0007)]
	  mtime = s.mtime.gmtime
	  yield wd.open(@name) {|f| [f.read, Attr.new(mtime, mode)]}
	}
      end

      def annotate(rev)
	r, w = IO.pipe
	r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
        @dir.run_cvs(['annotate', '-r' + rev.to_s, @name], w, '/dev/null', [], nil, lambda {
	  w.close
	  while line = r.gets
	    if /\A([0-9.]+) +\(([^ ]+) +(..)-(...)-(..)\): / =~ line
	      rev = Revision.create($1)
	      author = $2
	      date = Time.gm($5.to_i, $4, $3.to_i)
	      contents = $'
	      yield contents, date, rev, author
	    end
	  end
	  r.close
	})
      end

      def mkbranch(rev, tag)
        @dir.run_cvs(['tag', '-b', '-r' + rev.to_s, tag, @name], '/dev/null', '/dev/null')
	return head(tag)
      end

      def head(tag=nil)
        return heads[tag]
      end

      # ruby -rcvs -e 'CVS.create("/home/akr/.cvsroot//ccvs//ChangeLog").heads.each {|t, h| print "#{t || \"*maintrunk*\"} #{h}\n"}'
      def heads
	return parse_log(HeadsVisitor.new(self))
      end

      class HeadsVisitor < Visitor
	def initialize(file, headclass=Head)
	  @file = file
	  @headclass = headclass
	  @heads = {}
	  @tags = {}
	  @branches = {}
	  @states = {}
	  @head = nil
	end

	def head(rev)
	  @head = rev
	end

        def symbol(tag, rev)
	  @tags[tag] = rev if rev.branch?
	end

	def delta_without_next(rev, date, author, state, branches)
	  @states[rev] = state
	  b = rev.branch
	  if @branches.has_key? b
	    if @branches[b] < rev
	      @branches[b] = rev
	    end
	  else
	    @branches[b] = rev
	  end
	end

	def finished(buf)
	  @heads[nil] = @headclass.new(@file, nil, nil, @head, @states[@head])
	  @tags.each {|tag, b|
	    if @branches.has_key? b
	      rev = @branches[b]
	      @heads[tag] = @headclass.new(@file, tag, b, rev, @states[rev])
	    else
	      rev = b.origin
	      @heads[tag] = @headclass.new(@file, tag, b, rev, @states[rev])
	    end
	  }
	  return @heads
	end
      end

      def newhead(branch_tag, branch_rev, head_rev, state)
	return Head.new(self, branch_tag, branch_rev, head_rev, state)
      end
      class Head < CVS::F::Head
        def initialize(file, branch_tag, branch_rev, head_rev, state)
	  @file = file
	  @branch_tag = branch_tag
	  @branch_rev = branch_rev
	  @head_rev = head_rev
	  @state = state
	end
	attr_reader :file, :branch_tag, :branch_rev, :head_rev, :state

	def next_rev
	  if @branch_tag
	    if @branch_rev.origin == @head_rev
	      return @branch_rev.first
	    else
	      return @head_rev.next
	    end
	  else
	    return @head_rev.next
	  end
	end

	def add(contents, log)
	  raise AlreadyExist.new("already exist: #{@file.inspect}:#{@head_rev}") if @state != 'dead'
	  newrev = nil
	  r, w = IO.pipe
	  r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	  w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
	  @file.dir.run_cvs(['commit', '-f', '-m', log, @file.name], w, '/dev/null', [], lambda {|wd|
	    wd.open(@file.name, 'w') {|f| f.print(contents)}
	    wd.entries[@file.name] = "0/dummy/-ko/#{@branch_tag && ('T' + @branch_tag)}"
	    wd.update_entries
	  }, lambda {|wd|
	    w.close
	    while line = r.gets
	      if /^initial revision: ([0-9.]+)$/ =~ line
		newrev = Revision.create($1)
	      elsif /^new revision: ([0-9.]+); previous revision: [0-9.]+$/ =~ line
		newrev = Revision.create($1)
	      end
	    end
	    r.close
	  })
	  raise UnexpectedResult.new("unexpected revision added: #{newrev} instead of #{next_rev}") if next_rev != newrev
	  @head_rev = newrev
	  @state = 'Exp'
	  return newrev
	end

	def checkin(contents, log)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  newrev = nil
	  r, w = IO.pipe
	  r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	  w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
	  @file.dir.run_cvs(['commit', '-f', '-m', log, @file.name], w, '/dev/null', [], lambda {|wd|
	    wd.open(@file.name, 'w') {|f| f.print(contents)}
	    wd.entries[@file.name] = "#{@head_rev}/dummy/-ko/#{@branch_tag && ('T' + @branch_tag)}"
	    wd.update_entries
	  }, lambda {|wd|
	    w.close
	    while line = r.gets
	      if /^new revision: ([0-9.]+); previous revision: [0-9.]+$/ =~ line
		newrev = Revision.create($1)
	      end
	    end
	    r.close
	  })
	  raise UnexpectedResult.new("unexpected revision checkined: #{newrev} instead of #{next_rev}") if next_rev != newrev
	  @head_rev = newrev
	  return newrev
	end

	def remove(log)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  newrev = nil
	  r, w = IO.pipe
	  r.fcntl(Fcntl::F_SETFD, r.fcntl(Fcntl::F_GETFD) | 1)
	  w.fcntl(Fcntl::F_SETFD, w.fcntl(Fcntl::F_GETFD) | 1)
	  @file.dir.run_cvs(['commit', '-f', '-m', log, @file.name], w, '/dev/null', [], lambda {|wd|
	    wd.entries[@file.name] = "-#{@head_rev}/dummy timestamp/-ko/#{@branch_tag && ('T' + @branch_tag)}"
	    wd.update_entries
	  }, lambda {|wd|
	    w.close
	    while line = r.gets
	      if /^new revision: delete; previous revision: ([0-9.]+)$/ =~ line
		rev = Revision.create($1)
		if rev.branch?
		  newrev = rev.first
		else
		  newrev = rev.next
		end
	      end
	    end
	    r.close
	  })
	  raise UnexpectedResult.new("unexpected revision removed: #{newrev} instead of #{next_rev}") if next_rev != newrev
	  @head_rev = newrev
	  @state = 'dead'
	  return newrev
	end

	class UnexpectedResult < StandardError
	end
	class AlreadyExist < StandardError
	end
	class NotExist < StandardError
	end
      end

      def to_s
	return "<#{self.class} #{@dir.cvsroot.cvsroot}//#{@dir.path}//#{@attic ? 'Attic/' : ''}#{@name}>"
      end

      def inspect
	return self.to_s
      end
    end
  end
end
