class Diff
  class EditScript
    def initialize
      @list = []
      @chunk_add = nil
      @chunk_del = nil
      @chunk_common = nil

      @cs = Subsequence.new
      @count_a = 0
      @count_b = 0
      @additions = 0
      @deletions = 0
    end

    attr_reader :count_a, :additions
    attr_reader :count_b, :deletions

    def commonsubsequence
      return @cs
    end

    def del(seq_or_len)
      unless @chunk_del
	@chunk_add = []
	@chunk_del = []
	@chunk_common = nil
        @list << @chunk_del
        @list << @chunk_add
      end
      if Array === seq_or_len
	len = seq_or_len.length
	mark = :del_elt
      else
	len = seq_or_len
	mark = :del_num
      end
      if !@chunk_del.empty? && @chunk_del.last[0] == mark
	@chunk_del.last[1] += seq_or_len
      else
	@chunk_del << [mark, seq_or_len]
      end
      @count_a += len
      @deletions += len
    end

    def add(seq_or_len)
      unless @chunk_add
	@chunk_add = []
	@chunk_del = []
	@chunk_common = nil
        @list << @chunk_del
        @list << @chunk_add
      end
      if Array === seq_or_len
	len = seq_or_len.length
	mark = :add_elt
      else
	len = seq_or_len
	mark = :add_num
      end
      if !@chunk_add.empty? && @chunk_add.last[0] == mark
	@chunk_add.last[1] += seq_or_len
      else
	@chunk_add << [mark, seq_or_len]
      end
      @count_b += len
      @additions += len
    end

    def common(seq_or_len_a, seq_or_len_b=seq_or_len_a)
      unless @chunk_common
	@list.pop
	@list.pop
	@list << @chunk_del unless @chunk_del.empty?
	@list << @chunk_add unless @chunk_add.empty?
	@chunk_add = nil
	@chunk_del = nil
	@chunk_common = []
        @list << @chunk_common
      end

      len_a = Array === seq_or_len_a ? seq_or_len_a.length : seq_or_len_a
      len_b = Array === seq_or_len_b ? seq_or_len_b.length : seq_or_len_b
      raise ArgumentError.new("length not equal") if len_a != len_b
      len = len_a

      mark = ((Array === seq_or_len_a) ?
              (Array === seq_or_len_b ? :common_elt_elt : :common_elt_num) :
	      (Array === seq_or_len_b ? :common_num_elt : :common_num_num))

      if !@chunk_common.empty? && @chunk_common.last[0] == mark
	@chunk_common.last[1] += seq_or_len_a
	@chunk_common.last[2] += seq_or_len_b
      else
	@chunk_common << [mark, seq_or_len_a, seq_or_len_b]
      end

      @cs.add @count_a, @count_b, len
      @count_a += len
      @count_b += len
    end

    def each
      @list.each {|chunk|
        chunk.each {|mark, data|
	  case mark
	  when :add_elt
	    data.each {|elt| yield mark, nil, elt}
	  when :del_elt
	    data.each {|elt| yield mark, elt, nil}
	  when :common_elt
	    data.each {|elt| yield mark, elt, elt}
	  when :add_num
	    yield mark, 0, data
	  when :del_num
	    yield mark, data, 0
	  when :common_num
	    yield mark, data, data
	  end
	}
      }
    end
  end
end
