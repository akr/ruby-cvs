#!/usr/bin/env ruby
=begin
= rsp.rb - Ruby Server Pages :-)

== Example
=== envlist.cgi:
  require 'rsp'
  require 'cgi'

  print "Content-Type: text/html\n\n"

  print RSP.load('envlist.rsp').new(
    ENV.keys.sort.collect {|k|
      RSP[
        :key => k,
        :value => ENV[k]
      ]}).gen

=== envlist.rsp:
  <html>
  <head>
  <title>Environment variable list</title>
  </head>
  <body>
  <dl>
  <%each_with {%>
  <dt><%=CGI::escapeHTML key%></dt>
  <dd><%=CGI::escapeHTML value%></dd>
  <%}%>
  </dl>
  </body>
  </html>

== Supported syntax:

: <%-- comment --%>
: <%# comment %>
: <%! declaration %>
: <%= expression %>
: <% code fragment %>
: <%@ include file="..." %>
: <%%
: %%>

=end

require 'md5'

class Array
  def each_with(&block)
    proc = eval("lambda {|v, b| with(v, &b)}", block)
    each {|v| proc.call(v, block)}
  end
end

class RSP
  def RSP.compile_file(filename)
    if /\.rsp\z/ =~ filename
      compiledname = "#{$`}.rspc"
    else
      compiledname = "#{filename}.rspc"
    end

    begin
      s1 = File.stat(filename)
      s2 = File.stat(compiledname)
      return open(compiledname) {|f| f.read} if s1.mtime < s2.mtime
    rescue Errno::ENOENT
    end

    code = compile_code(filename)
    check_code(code)

    begin
      tmpname = compiledname + ".#{$$}"
      open(tmpname, 'w') {|f| f.print code}
      File.rename(tmpname, compiledname)
    rescue Errno::EACCES
    end

    return code
  end

  def RSP.check_code(code)
    err = Thread.start {
      $SAFE=4
      begin
	eval "lambda { #{code}\n}"
	nil
      rescue SyntaxError
	$!
      end
    }.value

    if err
      raise err
    end
  end

  def RSP.load(filename)
    return eval compile_file(filename)
  end

  def RSP.load_source(filename)
    return eval compile_code(filename)
  end

  def RSP.compile_code(filename)
    class_code = StringBuffer.new
    gen_body = StringBuffer.new
    depend = []
    compile_template(class_code, gen_body, filename, depend)
    return depend.collect {|name, mtime, md5| <<"End"}.join + <<"End"
# #{mtime.gmtime.strftime('%Y/%m/%d %H:%M:%S')} #{md5} #{name}
End
require 'rsp'
Class.new.class_eval {
def initialize(obj)
  @objs = [obj]
end

def method_missing(msg_id, *args, &block)
  @objs.reverse_each {|obj|
    return obj.send(msg_id, *args, &block) if obj.respond_to?(msg_id)
  }
  raise StandardError.new("method `\#{msg_id}' not found")
end

def with(obj)
  begin
    @objs.push(obj)
    yield
  ensure
    @objs.pop
  end
end

#{class_code}
def gen
  buf = RSP::StringBuffer.new
#------------------------------------------------------------
#{gen_body}
#------------------------------------------------------------
  return buf.to_s
end
if __FILE__ != $0
  self
else
  print self.new(Object.new).gen
end
}
End
  end
  class RSPError < StandardError
  end

  def RSP.register_string(class_code, strhash, data)
    if strhash.include?(data)
      name = strhash[data]
    else
      name = "STR#{strhash.size}"
      strhash[data] = name
      class_code << name << ' = ' << data.dump << "\n"
    end
    return name
  end

  def RSP.compile_template(class_code, gen_body, filename, depend=[], strhash={})
    mtime, template = open(filename) {|f| [f.stat.mtime, f.read]}
    depend << [filename, mtime, MD5.md5("abc").hexdigest]

    state = :contents
    linenumber = 1
    line_open = nil
    template.split(/(<%%|%%>|<%|%>)/).each {|data|
      case state
      when :contents
	case data
        when '<%%'
	  gen_body << 'buf << ' << register_string(class_code, strhash, '<%') << "\n"
        when '%%>'
	  gen_body << 'buf << ' << register_string(class_code, strhash, '%>') << "\n"
        when '<%'
	  state = :code
	  line_open = linenumber
        when '%>'
	  raise RSPError.new("#{filename}:#{linenumber}: unmatched '%>'")
	when ''
	  # ignore empty string.
	else
	  gen_body << 'buf << ' << register_string(class_code, strhash, data) << "\n"
	  linenumber += data.tr("^\n", '').length
	end
      when :code
	case data
        when '<%', '<%%'
	  raise RSPError.new("#{filename}:#{linenumber}: nested '<%'")
        when '%%>'
	  raise RSPError.new("#{filename}:#{linenumber}: code contains '%%>'")
        when '%>'
	  state = :contents
	  line_open = nil
	else
	  case data
	  when /\A!/
	    class_code << $' << "\n"
	  when /\A=/
	    gen_body << "buf << (#{$'}).to_s\n"
	  when /\A@\s*/
	    data = $'
	    case data
	    when /include\s+file="(.*)"\s*\z/
	      RSP.compile_template(class_code, gen_body,
		File.dirname(filename) + '/' + $1, depend, strhash)
	    else
	      raise RSPError.new("#{filename}:#{linenumber}: unknown directive: #{data}")
	    end
	  when /\A#/, /\A--[\000-\377]*--\z/
	  else
	    gen_body << data << "\n"
	  end
	  linenumber += data.tr("^\n", '').length
	end
      end
    }
    raise RSPError.new("#{filename}:#{line_open}: non-terminated Ruby code") if state != :contents
  end

  def RSP.[](hash)
    return RSP.new(hash)
  end

  def initialize(hash={})
    @hash = hash.dup
  end

  def method_missing(sym, *args)
    if @hash.include? sym
      return @hash[sym]
    elsif /=\z/ =~ (str = sym.id2name)
      @hash[$`.intern] = args[0]
    else
      raise ArgumentError.new("#{sym} not found")
    end
  end

  def respond_to?(name, priv=false)
    return @hash.include?(name) || super(name, priv)
  end

  class StringBuffer
    def initialize
      @bufs = []
      @buf = []
    end

    def <<(string)
      @buf << string
      if 4096 <= @buf.length
	buf = @buf.slice!(0, @buf.length).join
	if i = @bufs.rindex(nil)
	  @bufs[i] = @bufs[i+1..-1].join + buf
	  @bufs.fill(nil, (i+1)..-1)
	else
	  @bufs.unshift(@bufs.join + buf)
	  @bufs.fill(nil, 1..-1)
	end
      end
      return self
    end

    def each
      @bufs.each {|s| yield s if s}
      yield @buf.join
    end

    def to_s
      return (@bufs + @buf).join
    end
  end
end

if __FILE__ == $0
  $" << 'rsp.rb'

  def usage(status)
      print <<End
Usage: rsp [-h] [-c] [-p] rsp-file...
End
    exit(status)
  end

  require 'getoptlong'
  getopts = GetoptLong.new(
    [GetoptLong::NO_ARGUMENT, '-h'],
    [GetoptLong::NO_ARGUMENT, '-c'],
    [GetoptLong::NO_ARGUMENT, '-p'])

  mode = :run
  getopts.each {|opt, arg|
    case opt
    when '-h'
      usage(0)
    when '-c'
      mode = :compile
    when '-p'
      mode = :print
    else
      usage(1)
    end
  }

  ARGV.each {|arg|
    case mode
    when :run
      print eval(RSP.compile_file(arg)).new(Object.new).gen
    when :sourcerun
      print eval(RSP.compile_code(arg)).new(Object.new).gen
    when :compile
      begin
	RSP.compile_file(arg)
      rescue Exception
	STDERR.print "#{arg} has an error.\n"
	raise
      end
    when :print
      print RSP.compile_code(arg)
    end
  }
end

