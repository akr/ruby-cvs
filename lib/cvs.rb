=begin
= cvs.rb - CVS library for Ruby.
=end

=begin
== CVS
Abstract CVS repository class.
=end
class CVS
=begin
--- CVS.create(arg)
    CVS.create is an intelligent factory method for CVS objects.
     cvsroot//                  => CVS repository object.
     cvsroot//dir               => CVS directory object.
     cvsroot//dir//             => CVS directory object. (same as above.)
     cvsroot//dir//file         => CVS file object.
     cvsroot//dir//Attic/file   => CVS file object which is placed in Attic.

    If cvsroot begins with `/', a instantiated obect accesseses a repository
    directly.  Otherwise, the object accesses the repository by cvs command.
    I.e. this module works well with remote repositories as well as local
    repositores.  It gets speed advantages with local repositories. 
   
    If the argument doesn't contain `//' and begins with `/',
    CVS.create searches a CVSROOT directory and RCS file in given argument
    and instantiate a suitable object.
    If it doesn't begins with `/', instantiate a remote CVS repository object.
   
    Syntax:
     cvs_create_arg = exact_arg | ambiguous_arg
     exact_arg = cvsroot '//' [directory ['//' [file]]] | 
     cvsroot = local_cvsroot | remote_cvsroot
     local_cvsroot = <cvsroot begins with '/'>
     remote_cvsroot = <cvsroot not begins with '/'>
     directory = '.' | path
     path = name | name '/' path
     file = ['Attic/'] name
     name = <filename>
     ambiguous_arg = '/' path
=end
  def self.create(arg)
    if /\/\// =~ arg
      cvsroot = $`
      rest = $'
      c = /\A\// =~ arg ? L : R
      return c.new(cvsroot) if rest == ''
      if /\/\// =~ rest
        path = $`
        file = $'
        return c.new(cvsroot).dir(path) if file == ''
        attic = file.sub!(/\AAttic\//, '') != nil
        return c.new(cvsroot).dir(path).file(file, attic)
      else
        return c.new(cvsroot).dir(rest)
      end
    else
      if /\A\// =~ arg
        arg.scan(/\//) {
          if FileTest.directory?($` + '/CVSROOT')
            cvsroot = L.new($`)
            path = $'
            if FileTest.directory?(arg)
              return cvsroot.dir(path)
            elsif /\/Attic\/([^\/]+),v\z/ =~ path && FileTest.file?(arg)
              return cvsroot.dir($`).file($1, true)
            elsif /,v\z/ =~ path && FileTest.file?(arg)
              return cvsroot.file($`)
            elsif /\/Attic\/([^\/]+)\z/ =~ path && FileTest.file?(arg + ',v')
              return cvsroot.dir($`).file($1, true)
            elsif FileTest.file?(arg + ',v')
              return cvsroot.file(path)
            elsif FileTest.file?(File.dirname(arg) + '/Attic/' + File.basename(arg) + ',v')
              return cvsroot.dir(File.dirname(path)).file(File.basename(path), true)
            else
              raise CVSCreationError.new("cannot find CVS file or directory: #{arg}")
            end
          end
        }
        if FileTest.directory?(arg + '/CVSROOT')
          return L.new(arg)
        else
          raise CVSCreationError.new("cannot find CVS repositrory: #{arg}")
        end
      else
        return R.new(arg)
      end
    end
  end
  class CVSCreationError < StandardError
  end

=begin
--- cvsroot
    returns CVSROOT as an string.
=end
  def cvsroot
    raise NotImplementedError.new
  end

=begin
--- top_dir
    creates a CVS directory object which points top directory of the repository.
=end
  def top_dir
    raise NotImplementedError.new
  end

=begin
--- dir(path)
    creates a CVS directory object which points `path'.
=end
  def dir(name)
    return top_dir.dir(name)
  end

=begin
--- file(path[, attic])
    creates a CVS file object which points `path'.

    `attic' specify whether the file is placed in Attic.
=end
  def file(name, attic=nil)
    if /\/([^\/]*)\z/ =~ name
      return dir($`).file($1, attic)
    else
      return dir('.').file($1, attic)
    end
  end

=begin
== CVS::D
Abstract CVS directory class.
=end
  # `M' (module) is better? not?
  class D # directory
=begin
--- cvsroot
    returns the CVS repository object.
=end
    def cvsroot
      raise NotImplementedError.new
    end

=begin
--- path
    returns a path from a top directory of the repository.
=end
    def path
      raise NotImplementedError.new
    end

=begin
--- simple_dir(name)
    creates a CVS directory object for direct subdirectory.
=end
    def simple_dir(name)
      raise NotImplementedError.new
    end

=begin
--- simple_file(name[, attic])
    creates a CVS file object for a file contained by the directory.
=end
    def simple_file(name, attic=nil)
      raise NotImplementedError.new
    end

=begin
--- dir(path)
    creates a CVS directory object for a directory under the directory.
=end
    def dir(path)
      if /\// =~ path
	return simple_dir($`).dir($')
      else
	return simple_dir(path)
      end
    end

=begin
--- file(path[, attic])
    creates a CVS file object for a file under the directory.
=end
    def file(path, attic=nil)
      if /\/([^\/]*)\z/ =~ path
	return dir($`).file($1, attic)
      else
	return simple_file(path, attic)
      end
    end

=begin
--- listdir
    returns an array of CVS directory objects which represent subdirectories.
=end
    def listdir
      raise NotImplementedError.new
    end

=begin
--- listfile
    returns an array of CVS file objects for non-directory files directly under
    the directory.
=end
    def listfile
      raise NotImplementedError.new
    end

=begin
--- parse_log(visitor[, opts])
    run `cvs log' or `rlog' for all non-directory files in the directory.
=end
    def parse_log(visitor, opts=[])
      listfile.each {|f|
        f.parse_log(visitor, opts)
      }
    end
  end

=begin
== CVS::F
Abstract CVS file class.
=end
  class F # file
=begin
--- dir
    returns the CVS directory object.
=end
    def dir
      raise NotImplementedError.new
    end

=begin
--- name
    returns the filename.
=end
    def name
      raise NotImplementedError.new
    end

=begin
--- attic
    returns attic info.
=end
    def attic
      raise NotImplementedError.new
    end

=begin
--- path
    returns a path from a top directory of the repository.
=end
    def path
      return self.dir.path + '/' + self.name
    end

=begin
--- parse_log(visitor[, opts])
    run `cvs log' or `rlog' for the file.
=end
    def parse_log(visitor, opts=[])
      raise NotImplementedError.new
    end

=begin
--- tags
    returns a hash which maps a tag to a revision.
=end
    def tags
      raise NotImplementedError.new
    end

=begin
--- checkout(rev) {|contents, attr| ...}
=end
    def checkout(rev)
      raise NotImplementedError.new
    end

=begin
--- annotate(rev) {|line, date, rev, author| ...}
=end
    def annotate(rev)
      raise NotImplementedError.new
    end

=begin
--- head([tag])
    creates a head object.

    If `tag' is not specified, a head object for main trunk is created.
=end
    def head(rev=nil)
      raise NotImplementedError.new
    end

=begin
--- heads
    returns a hash which maps a tag to a head object.

    The hash contains a head object for main trunk as a value of nil as a key.
=end
    def heads
      raise NotImplementedError.new
    end

=begin
== CVS::F::Head
Abstract CVS head class.
=end
    class Head
=begin
--- add(contents, log)
=end
      def add(contents, log)
	raise NotImplementedError.new
      end

=begin
--- checkin(contents, log)
=end
      def checkin(contents, log)
	raise NotImplementedError.new
      end

=begin
--- remove(log)
=end
      def remove(log)
	raise NotImplementedError.new
      end

    end
  end

=begin
== CVS::Attr
CVS file attribute class
=end
  class Attr
    def initialize(mtime, mode)
      @mtime = mtime
      @mode = mode
    end
    attr_reader :mtime, :mode
=begin
--- mtime
--- mode
=end
  end

end

require 'cvs/revision'
require 'cvs/tempdir'
require 'cvs/parser'
require 'cvs/remote'
require 'cvs/local'
require 'cvs/cache'

begin
  require 'cvs/flex'
rescue LoadError
end

# example:

# require 'cvs'

## needs read permission only:

# c = CVS.create(':pserver:anonymous@cvs.m17n.org:/cvs/root')
# c.dir('.').listdir.each {|d| p d.path}
# c.dir('gnus').listdir.each {|d| p d.path}
# c.dir('gnus/lisp').listfile.each {|f| p f.name}
# c.dir('semi').parse_log(CVS::Visitor::Dump.new)
# c.file('flim/ChangeLog').tags.each {|tag,rev| p [tag,rev.to_s]}
# c.file('flim/DOODLE-VERSION').tags.each {|tag,rev| p [tag,rev.to_s]}  # cvs.rb handles attic-ness for you.
# c.file('semi/ChangeLog').parse_raw_log(CVS::Visitor::Dump.new)
# c.file('semi/ChangeLog').parse_log(CVS::Visitor::Dump.new)
# c.file('flim/ChangeLog').checkout(CVS::Revision.create("1.1.1.1")) {|d, a| p a; print d}
# c.file('apel/ChangeLog').heads.each {|t, h| print "#{t||'*maintrunk*'} #{h}\n"}
# c.file('flim/ChangeLog').annotate(CVS::Revision.create("1.30")) {|line, date, rev, author| p [line, date, rev.to_s, author]}

## needs write permission (works with remote repositories):

# c = CVS.create(':fork:/home/foo/.cvsroot')
# h = c.file('tst/a').heads[nil]	# nil means main trunk.
# h.checkin('modified contents', 'log2')
# h.remove('log3')
# h.add('re-added contents', 'log4')

## needs to be local repository:

# c = CVS.create('/home/foo/.cvsroot')
# c.file('cvs/ChangeLog').parse_raw_rcs(CVS::Visitor::Dump.new)
# c.file('cvs/ChangeLog').fullannotate(CVS::Revision.create("1.30")) {|line, date1, rev1, author, rev2, date2| p [line, date1, rev1.to_s, author, rev2.to_s, date2]}
