class CVS
  class TempDir
    @@tempdir = nil
    def self.create(keyword='ruby-cvs')
      @@tempdir = TempDir.new unless @@tempdir
      return @@tempdir.newdir
    end

    def initialize(keyword='ruby-cvs')
      tmp = ENV['TMPDIR'] || '/tmp'
      i = 0
      begin
        @dir = tmp + "/#{keyword}-#{$$}-#{Time.now.to_i}-#{i}"
	Dir.mkdir(@dir)
      rescue
	i += 1
	retry
      end
      @base = 'a'
      ObjectSpace.define_finalizer(self, TempDir.cleanup(@dir))
    end

    def TempDir.cleanup(dir)
      pid = $$
      return lambda {
	if pid == $$
	  # The directory may be deleted by a finalizer of ancestor temporary
	  # directory.
	  if FileTest.directory? dir
	    system '/bin/rm', '-rf', dir
	  end
	end
      }
    end

    def newbase
      base = @base.dup
      @base.succ!
      return base
    end

    def path(base=nil)
      if base
        return @dir + '/' + base
      else
        return @dir
      end
    end

    def mkdir(base=newbase)
      Dir.mkdir(path(base))
    end

    def open(base, *rest)
      if block_given?
	return File.open(path(base), *rest) {|f| yield f}
      else
	return File.open(path(base), *rest)
      end
    end

    def newdir(base=newbase)
      return Sub.new(self, path(base))
    end

    class Sub < TempDir
      def initialize(parent, dir)
	# The purpose of @parent is to control GC and finalizer.
	# If @parent is not exist, parent (or ancestor) object may be
	# collected before all decendants are collected.  It causes problem
	# because the finalizer removes directory recursively (by `rm -rf')
	# including the directories created by living objects of Sub.
        @parent = parent
	@dir = dir
	Dir.mkdir(dir)
	@base = 'a'
	ObjectSpace.define_finalizer(self, TempDir.cleanup(@dir))
      end
    end
  end
end
