# cvs.rb - CVS library for Ruby.

# TODO:
#   grab more codes from CVSsuck.
#   talk CVS client/server protocol directly.

class CVS
  # CVS.create is an intelligent factory method for CVS objects.
  #  cvsroot//			=> CVS repository object.
  #  cvsroot//dir		=> CVS directory object.
  #  cvsroot//dir//		=> CVS directory object. (same as above.)
  #  cvsroot//dir//file		=> CVS file object.
  #  cvsroot//dir//Attic/file	=> CVS file object which is contained in Attic.
  # 
  # If cvsroot begins with `/', a instantiated obect accesseses a repository
  # directly.  Otherwise, the object accesses the repository by cvs.
  # I.e. this module works well with remote repositories as well as local
  # repositores. It gets speed advantages with local repositories. 
  #
  # If the argument doesn't contain `//' and begins with `/',
  # CVS.create searches a CVSROOT directory and RCS file in given argument
  # and instantiate a suitable object.
  # If it doesn't begins with `/', instantiate a remote CVS repository object.
  #
  # Syntax:
  #  cvs_create_arg = exact_arg | ambiguous_arg
  #  exact_arg = cvsroot '//' [directory ['//' [file]]] | 
  #  cvsroot = local_cvsroot | remote_cvsroot
  #  local_cvsroot = <cvsroot begins with '/'>
  #  remote_cvsroot = <cvsroot not begins with '/'>
  #  directory = '.' | path
  #  path = name | name '/' path
  #  file = ['Attic/'] name
  #  name = <filename>
  #  ambiguous_arg = '/' path
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

  # `M' (module) is better? not?
  class D # directory
  end

  class F # file
    def path
      return self.dir.path + '/' + self.name
    end
  end

  class Attr
    def initialize(mtime, mode)
      @mtime = mtime
      @mode = mode
    end
    attr_reader :mtime, :mode
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
# c.file('flim/ChangeLog').tags.each {|tag,rev| p [tag,rev.to_s]}
# c.file('flim/DOODLE-VERSION').tags.each {|tag,rev| p [tag,rev.to_s]}  # cvs.rb handles attic-ness for you.
# c.file('semi/ChangeLog').parse_raw_log(CVS::Visitor::Dump.new)
# c.file('semi/ChangeLog').parse_log(CVS::Visitor::Dump.new)
# c.file('flim/ChangeLog').checkout(CVS::Revision.create("1.1.1.1")) {|f, a| p a; print f.read}
# c.file('apel/ChangeLog').heads.each {|t, h| print "#{t||'*maintrunk*'} #{h}\n"}

## needs write permission (works with remote repositories):

# c = CVS.create(':fork:/home/xxx/.cvsroot')
# h = c.file('tst/a').heads[nil]	# nil means main trunk.
# h.checkin('modified contents', 'log2')
# h.remove('log3')
# h.add('re-added contents', 'log4')

## needs to be local repository:

# c = CVS.create('/home/xxx/.cvsroot')
# c.file('cvs/ChangeLog').parse_raw_rcs(CVS::Visitor::Dump.new)
