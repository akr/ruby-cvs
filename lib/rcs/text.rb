class RCS
  class Text
    def initialize(text, annotate=nil)
      text = Text.split(text) if String === text
      text.collect! {|line| annotate.call(line) || false} if annotate
      @text = text
    end

    def lines
      return @text
    end

    def to_s
      return @text.join('')
    end

    def Text.split(str)
      a = []
      str.each_line("\n") {|l| a << l}
      return a
    end

    def Text.parse_diff(diff)
      state = :command
      beg = len = nil
      adds = nil
      diff.each_line("\n") {|line|
	case state
	when :command
	  case line
	  when /\Aa(\d+)\s+(\d+)/
	    beg = $1.to_i
	    len = $2.to_i
	    adds = []
	    state = :add
	  when /\Ad(\d+)\s+(\d+)/
	    beg = $1.to_i
	    len = $2.to_i
	    yield :del, beg, len, nil
	    state = :command
	  else
	    raise InvalidDiffFormat.new(line)
	  end
	when :add
	  adds << line
	  if adds.length == len
	    yield :add, beg, len, adds
	    adds = nil
	    state = :command
	  end
	else
	  raise StandardError.new("unknown state")
	end
      }
    end

    def patch!(diff, annotate_add=nil, annotate_del=nil)
      text = @text.dup
      text.unshift(nil) # adjust array index as line number.
      Text.parse_diff(diff) {|com, beg, len, adds|
	if com == :add
	  adds.collect! {|line| annotate_add.call(line) || false} if annotate_add
	  text[beg] = [text[beg], adds]
	else
	  text[beg, len].each {|line| annotate_del.call(line)} if annotate_del
	  text.fill(nil, beg, len)
	end
      }
      text.flatten!
      text.compact!
      @text = text
      return self
    end

    def patch(diff, annotate_add=nil, annotate_del=nil)
      return self.dup.patch!(diff, annotate_add, annotate_del)
    end

    class InvalidDiffFormat < StandardError
    end
  end
end
