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
=end

class Array
  def each_with(&block)
    each {|v|
      eval("lambda {|v, b| with(v, &b)}", block).call(v, block)
    }
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

    code = compile_code(open(filename) {|f| f.read})

    begin
      tmpname = compiledname + ".#{$$}"
      open(tmpname, 'w') {|f| f.print code}
      File.rename(tmpname, compiledname)
    rescue Errno::EACCES
    end

    return code
  end

  def RSP.load(filename)
    return eval compile_file(filename)
  end

  def RSP.load_source(filename)
    return eval compile_code(open(filename) {|f| f.read})
  end

  def RSP.compile_code(template)
    class_code = StringBuffer.new
    gen_body = StringBuffer.new

    state = :contents
    linenumber = 1
    line_open = nil
    template.split(/(<%|%>)/).each {|data|
      case state
      when :contents
	case data
        when '<%'
	  state = :code
	  line_open = linenumber
        when '%>'
	  raise RSPError.new("#{linenumber}: unmatched '%>'")
	else
	  gen_body << 'buf << ' << data.dump << "\n"
	  data.tr!("^\n", '')
	  linenumber += data.length
	end
      when :code
	case data
        when '<%'
	  raise RSPError.new("#{linenumber}: nested '<%'")
        when '%>'
	  state = :contents
	  line_open = nil
	else
	  case data
	  when /\A!/
	    class_code << $' << "\n"
	  when /\A=/
	    gen_body << "buf << (#{$'}).to_s\n"
	  when /\A#/
	  else
	    gen_body << data << "\n"
	  end
	  linenumber += data.tr("^\n", '').length
	end
      end
    }
    raise RSPError.new("#{line_open}: non-terminated Ruby code") if state != :contents

    return <<"End"
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
self
}
End
  end
  class RSPError < StandardError
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
  ARGV.each {|filename|
    print RSP.compile_file(filename)
  }
end

