require 'flex'

class RCS
  class Parser
    class FlexScanner
      RE = Flex.new([nil, nil,
	'[ \b\t\n\v\f\r]+',
	'(@[^@]*@)+',
	'[0-9.]+',
	'[!"#%&\'()*+\\-./0123456789<=>?A-Z[\\\\\\]^_`a-z{|}~' + "\240-\377]+",
	';',
	':'])
      RE.opts |= Flex::OPT_REMEMBER

      def initialize(input)
	@in = input
	@re = RE.clone
	@chunksize = 8192
	@state = @re.most nil
      end

      def get
	# The order of comparison is optimized
	while true
	  if @state == 2 # white spaces
	    @state = @re.most nil
	  elsif @state == 5 # id
	    s = @re.yytext
	    @state = @re.most nil
	    return ID.new(s)
	  elsif @state == 4 # num
	    s = @re.yytext
	    @state = @re.most nil
	    return NUM.new(s)
	  elsif @state == 6 # ;
	    s = @re.yytext
	    @state = @re.most nil
	    return SEMI.new(s)
	  elsif @state == 3 # string
	    s = @re.yytext[1...-1]
	    s.gsub!(/@@/, '@')
	    @state = @re.most nil
	    return STR.new(s)
	  elsif @state == 7 # :
	    s = @re.yytext
	    @state = @re.most nil
	    return COLON.new(s)
	  elsif @state == 0 # needs more data
	    begin 
	      buf = @in.sysread(@chunksize)
	    rescue EOFError
	      return nil
	    end
	    @state = @re.most buf
	  elsif @state == 1 # not match
	    raise StandardError.new("parse error #{@re.ahead.inspect}")
	  else
	    raise StandardError.new("unexpected result of Flex#most")
	  end
	end
      end
    end
    @@scanner = FlexScanner
  end
end
