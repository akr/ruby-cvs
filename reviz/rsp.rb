=begin
= rsp.rb - Ruby Server Page :-)

== Example
=== envlist.cgi:
  require 'rsp'
  require 'cgi'

  class Env
    def title
      'Environment variable list'
    end
    def each
      ENV.each {|k, v| yield k, v}
    end
  end
  e = Env.new

  PageGen = RSP.load('envlist.rsp')

  print "Content-Type: text/html\n\n"
  print PageGen.new(e).gen
=== envlist.rsp:
  <html>
  <head>
  <title><%=title%></title>
  </head>
  <body>
  <dl>
  <%each {|k, v|%>
  <dt><%=CGI::escapeHTML(k)%></dt>
  <dd><%=CGI::escapeHTML(v)%></dd>
  <%}%>
  </dl>
  </body>
  </html>
=end

module RSP
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
      open(compiledname, 'w') {|f| f.print code}
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
    result = StringBuffer.new
    result << <<'End'
Class.new.class_eval {
def initialize(obj)
  @obj = obj
end
def method_missing(msg_id, *args, &block)
  @obj.send(msg_id, *args, &block)
end
def with(obj)
  save = @obj
  begin
    @obj = obj
    yield
  ensure
    @obj = save
  end
end
def gen
  buf = RSP::StringBuffer.new
#------------------------------------------------------------
End
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
	  result << 'buf << ' << data.dump << "\n"
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
	  result << compile_fragment(data)
	  data.tr!("^\n", '')
	  linenumber += data.length
	end
      end
    }
    raise RSPError.new("#{line_open}: non-terminated Ruby code") if state != :contents
    result << <<'End'
#------------------------------------------------------------
  return buf.to_s
end
self
}
End
    return result.to_s
  end
  class RSPError < StandardError
  end

  def RSP.compile_fragment(frag)
    case frag
    when /\A=/
      "buf << (#{$'}).to_s\n"
    when /\A#/
    else
      frag + "\n"
    end
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

  class Data
    def initialize(hash)
      @hash = hash.dup
    end

    def method_missing(msg_id, *args)
      if @hash.include? msg_id
	return @hash[msg_id]
      else
        raise ArgumentError.new("#{msg_id} not found")
      end
    end
  end
end