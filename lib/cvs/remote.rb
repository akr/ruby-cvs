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

    def newworkdir(dir)
      @workdir = WorkDir.new(top_dir, TempDir) unless @workdir
      return WorkDir.new(dir, @workdir)
    end

    class WorkDir < DelegateClass(TempDir)
      def initialize(dir, parent)
	@dir = dir
	super(parent.create)
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

      def basename
        return File.basename(path)
      end

      def run_cvs_raw(args, out=nil, err=nil, env=[])
	command = ['cvs', '-f', '-d', @dir.cvsroot.cvsroot]
	command += args
	pid = fork {
	  env.each {|k, v| ENV[k] = v}
	  if IO === out
	    STDOUT.reopen(out)
	  elsif out == nil
	    File.open('/dev/null', "w") {|f| STDOUT.reopen(f)}
	  else
	    File.open(out, "w") {|f| STDOUT.reopen(f)}
	  end
	  if IO === err
	    STDERR.reopen(err)
	  elsif err == nil
	    File.open('/dev/null', "w") {|f| STDERR.reopen(f)}
	  else
	    File.open(err, "w") {|f| STDERR.reopen(f)}
	  end
	  Dir.chdir(path('..'))
	  exec(*command)
	}
	Process.waitpid(pid, nil)
	status = $?
	if block_given?
	  return yield status
	else
	  return status
	end
      end

      def run_cvs(args, out='/dev/null', err='/dev/null', env=[])
        status = run_cvs_raw(args, out, err, env)
	raise CVSCommandFailure.new(status) if status != 0
	if block_given?
	  return yield status
	else
	  return status
	end
      end
      class CVSCommandFailure < StandardError
        def initialize(status)
	  super("status: #{status}")
	end
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
	  @work = @cvsroot.newworkdir(self)
	end
	yield @work
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
	with_work {|wd|
	  err = TempDir.global.newpath
	  wdname = wd.basename
	  wd.run_cvs(['update', '-r00', '-d', '-p', wdname], nil, err) {|status|
	    File.open(err) {|f|
	      f.each_line {|line|
		p line
		if / server: New directory `#{wdname}\/(.*)' -- ignored\n\z/ =~ line
		  res << simple_dir($1)
		end
	      }
	    }
	    File.unlink(err)
	  }
	}
	return res
      end

      def listfile
	res = []
	with_work {|wd|
	  out = TempDir.global.newpath
	  wdname = wd.basename
	  wd.run_cvs(['log', '-R', wdname], out) {|status|
	    File.open(out) {|f|
	      f.each_line {|line|
		if /\/(Attic\/)?([^\/]*),v\n\z/ =~ line
		  res << file($2, $1 != nil)
		end
	      }
	    }
	    File.unlink(out)
	  }
	}
	return res
      end

      def parse_log(visitor, opts=[])
        parse_raw_log(Parser::Log::LogVisitor.new(visitor), opts)
      end

      def parse_raw_log(visitor, opts=[])
	res = []
	with_work {|wd|
	  out = TempDir.global.newpath
	  wdname = wd.basename
	  wd.run_cvs(['log', *opts] << wdname, out) {|status|
	    File.open(out) {|f|
	      parser = Parser::Log.new(f)
	      until parser.eof?
	        res << parser.parse(visitor)
	      end
	    }
	    File.unlink(out)
	  }
	}
	return res
      end

      def mkdir(name)
	with_work {|wd|
	  wd.mkdir(name)
	  wdname = wd.basename
	  wd.run_cvs(['add', wdname + '/' + name])
	}
	return simple_dir(name)
      end

      def mkfile(name, contents, log, description='', branch_tag=nil)
	# `description' is ignored with a remote repository because
	# well known CVS bug.  (see BUGS file in CVS distribution.)
	# It is possible to avoid the bug by sending `add' and `commit'
	# request on SINGLE connection.  But it is impossible with cvs
	# COMMAND and it requires to talk CVS client/server protocol directly.
	newrev = nil
	with_work {|wd|
	  out = TempDir.global.newpath
	  wd.open("CVS/#{name},t", 'w') {|f| f.print(description)}
	  wd.open(name, 'w') {|f| f.print(contents)}
	  wd.entries[name] = "0//-ko/#{branch_tag && ('T' + branch_tag)}"
	  wd.update_entries
	  args = ['commit', '-f', '-m', log, wd.basename + '/' + name]
	  wd.run_cvs(args, out) {|status|
	    File.open(out) {|f|
	      f.each_line {|line|
		if /^initial revision: ([0-9.]+)$/ =~ line
		  newrev = RCS::Revision.create($1)
		elsif /^new revision: ([0-9.]+); previous revision: [0-9.]+$/ =~ line
		  newrev = RCS::Revision.create($1)
		end
	      }
	    }
	    File.unlink(out)
	  }
	}
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
	@dir.with_work {|wd|
	  out = TempDir.global.newpath
	  args = ['log', *opts]
	  args << (wd.basename + '/' + @name)
	  wd.run_cvs(args, out) {|status|
	    File.open(out) {|f|
	      res = Parser::Log.new(f).parse(visitor)
	    }
	    File.unlink(out)
	  }
	}
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
	@dir.with_work {|wd|
	  wd.run_cvs(['update', '-ko', '-r' + rev.to_s, wd.basename + '/' + @name])
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
	@dir.with_work {|wd|
	  out = TempDir.global.newpath
	  wd.run_cvs(['annotate', '-r' + rev.to_s, wd.basename + '/' + @name], out)
	  File.open(out) {|f|
	    f.each_line {|line|
	      if /\A([0-9.]+) +\(([^ ]+) +(..)-(...)-(..)\): / =~ line
		rev = RCS::Revision.create($1)
		author = $2
		date = Time.gm($5.to_i, $4, $3.to_i)
		contents = $'
		yield contents, date, rev, author
	      end
	    }
	  }
	  File.unlink(out)
	}
      end

      def mkbranch(rev, tag)
	@dir.with_work {|wd|
	  wd.run_cvs(['tag', '-b', '-r' + rev.to_s, tag, wd.basename + '/' + @name])
	}
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
	  @default_branch = nil
	  @default_branch_head = nil
	end

	def head(rev)
	  @head = rev
	end

	def branch(rev)
	  @default_branch = rev
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
	  if @default_branch && rev.on?(@default_branch)
	    if !@default_branch_head || @default_branch_head < rev
	      @default_branch_head = rev
	    end
	  end
	end

	def finished(buf)
	  @heads[nil] = @headclass.new(@file, nil, nil, @head, @states[@head], @default_branch_head)
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

      def newhead(branch_tag, branch_rev, head_rev, state, default_branch_head=nil)
	return Head.new(self, branch_tag, branch_rev, head_rev, state, default_branch_head)
      end
      class Head < CVS::F::Head
        def initialize(file, branch_tag, branch_rev, head_rev, state, default_branch_head=nil)
	  @file = file
	  @branch_tag = branch_tag
	  @branch_rev = branch_rev
	  @head_rev = head_rev
	  @state = state
	  @default_branch_head = default_branch_head
	end
	attr_reader :file, :branch_tag, :branch_rev, :head_rev, :state, :default_branch_rev, :default_branch_head

	def current_rev
	  if @default_branch_head && !@branch_rev
	    return @default_branch_head
	  else
	    return @head_rev
	  end
	end

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
	  @file.dir.with_work {|wd|
	    out = TempDir.global.newpath
	    wd.open(@file.name, 'w') {|f| f.print(contents)}
	    wd.entries[@file.name] = "0/dummy/-ko/#{@branch_tag && ('T' + @branch_tag)}"
	    wd.update_entries
	    wd.run_cvs(['commit', '-f', '-m', log, wd.basename + '/' + @file.name], out)
	    File.open(out) {|f|
	      f.each_line {|line|
		if /^initial revision: ([0-9.]+)$/ =~ line
		  newrev = RCS::Revision.create($1)
		elsif /^new revision: ([0-9.]+); previous revision: [0-9.]+$/ =~ line
		  newrev = RCS::Revision.create($1)
		end
	      }
	    }
	    File.unlink(out)
	  }
	  raise UnexpectedResult.new("unexpected revision added: #{newrev} instead of #{next_rev}") if next_rev != newrev
	  @head_rev = newrev
	  @state = 'Exp'
	  return newrev
	end

	def checkin(contents, log)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  newrev = nil
	  @file.dir.with_work {|wd|
	    out = TempDir.global.newpath
	    wd.open(@file.name, 'w') {|f| f.print(contents)}
	    wd.entries[@file.name] = "#{current_rev}/dummy/-ko/#{@branch_tag && ('T' + @branch_tag)}"
	    wd.update_entries
	    wd.run_cvs(['commit', '-f', '-m', log, wd.basename + '/' + @file.name], out)
	    File.open(out) {|f|
	      f.each_line {|line|
		if /^new revision: ([0-9.]+); previous revision: [0-9.]+$/ =~ line
		  newrev = RCS::Revision.create($1)
		end
	      }
	    }
	    File.unlink(out)
	  }
	  raise UnexpectedResult.new("unexpected revision checkined: #{newrev} instead of #{next_rev}") if next_rev != newrev
	  @head_rev = newrev
	  return newrev
	end

	def remove(log)
	  raise NotExist.new("not exist: #{@file.inspect}:#{@head_rev}") if @state == 'dead'
	  prev_rev = nil
	  @file.dir.with_work {|wd|
	    out = TempDir.global.newpath
	    wd.entries[@file.name] = "-#{current_rev}/dummy timestamp/-ko/#{@branch_tag && ('T' + @branch_tag)}"
	    wd.update_entries
	    wd.run_cvs(['commit', '-f', '-m', log, wd.basename + '/' + @file.name], out, '/dev/tty')
	    File.open(out) {|f|
	      f.each_line {|line|
		if /^new revision: delete; previous revision: ([0-9.]+)$/ =~ line
		  prev_rev = RCS::Revision.create($1)
		end
	      }
	    }
	    File.unlink(out)
	  }
	  raise UnexpectedResult.new("unexpected revision removed: #{prev_rev} instead of #{current_rev}") if current_rev != prev_rev
	  @head_rev = next_rev
	  @state = 'dead'
	  return @head_rev
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
