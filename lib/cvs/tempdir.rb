=begin
= CVS::TempDir - The class for hierarchical temporary directories.
=end
class CVS
  class TempDir
=begin
--- TempDir.create([keyword])
--- TempDir.create([keyword]) {|oldname| ...}
    creates temporary subdirectory under a process wide shared temporary
    directory.
=end
    @@tempdir = nil
    def self.create(keyword='ruby-cvs', &genname)
      @@tempdir = TempDir.new(keyword) unless @@tempdir
      return @@tempdir.newdir(&genname)
    end

=begin
--- TempDir.new([keyword])
--- TempDir.new([keyword]) {|oldname| ...}
    creates a new temporary directory and
    returns associated temporary directory object.
    `keyword' is used for prefix of temporary directory name.

    The temporary directory and all files under the directory is removed when
    the associated temporary directory object is collected as garbage.

    If a block is given, it is used to generate new filenames under the
    temporary directory.  It is called when new filename is requried.
    At first time it is called with nil as an argument and
    with previous filename for succeeding calls.
    If a block is not given, String#succ is used to generate filenames:
    `a', ..., `z', `aa', ..., `zz', `aaa', ...
=end
    def initialize(keyword='ruby-cvs', &genname)
      tmp = ENV['TMPDIR'] || '/tmp'
      i = 0
      begin
        @dir = tmp + "/#{keyword}-#{$$}-#{Time.now.to_i}-#{i}"
	Dir.mkdir(@dir)
      rescue
	i += 1
	retry
      end
      @name = nil
      @genname = genname || lambda {|old| old ? old.succ : 'a'}
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

    def newname
      @name = @genname.call(@name)
      return @name
    end

=begin
--- path([name])
    returns an absolute path.

    If `name' is not specified, an absolute path to the temporary directory is returned.
    If `name' is specified, `temporary directory'/`name' is returned.
=end
    def path(name=nil)
      if name
        return @dir + '/' + name
      else
        return @dir
      end
    end

=begin
--- mkdir([name])
    creates a directory under the temporary directory and
    returns an absolute path to the created directory.

    The name of created directory is specified by `name'.
    If it is not specified, the name is automatically generated.

    The created directory and its components are removed when the containing
    temporary directory is removed.
=end
    def mkdir(name=newname)
      dir = path(name)
      Dir.mkdir(dir)
      return dir
    end


=begin
--- open(name[, mode])
--- open(name[, mode]) {|file| ...}
    opens a file under the temporary directory.
=end
    def open(name, *rest)
      if block_given?
	return File.open(path(name), *rest) {|f| yield f}
      else
	return File.open(path(name), *rest)
      end
    end

=begin
--- newdir([name])
--- newdir([name]) {|oldname| ...}
--- create([name])
--- create([name]) {|oldname| ...}
    creates a temporary directory under the temporary directory and
    returns associated temporary directory object.

    The created temporary directory and all files under the directory is
    removed when the associated temporary directory object is collected
    as garbage.
    Note that parent directory object doesn't collected until all subdirectory
    objects are collected because a subdirectory object refer the parent
    temporary directory object. 
=end
    def newdir(name=newname, &genname)
      return Sub.new(self, path(name), &(genname || @genname))
    end
    alias create newdir

    class Sub < TempDir
      def initialize(parent, dir, &genname)
	# The purpose of @parent is to control GC and finalizer.
	# If @parent is not exist, parent (or ancestor) object may be
	# collected before all decendants are collected.  It causes problem
	# because the finalizer removes directory recursively (by `rm -rf')
	# including the directories created by living objects of Sub.
        @parent = parent
	@dir = dir
	Dir.mkdir(dir)
	@name = nil
	@genname = genname || lambda {|old| old ? old.succ : 'a'}
	ObjectSpace.define_finalizer(self, TempDir.cleanup(@dir))
      end
    end
  end
end
