class CVS
  class Revision
    class RevisionError < StandardError
    end
    def self.create(arg)
      case arg
      when NilClass
        return nil
      when String
	raise RevisionError.new(arg) unless /\A\d+(?:\.\d+)*\z/ =~ arg
	arr = []
	arg.scan(/\d+/) {|num| arr << num.to_i}
      when Array
        arr = arg
      else
	raise RevisionError.new(arg)
      end
      if (arr.length & 1) == 0 && 4 <= arr.length && arr[-2] == 0
	return Branch::Magic.new(arr[0...-2] + [arr[-1]])
      elsif (arr.length & 1) == 1
	return Branch.new(arr)
      else
	return NonBranch.new(arr)
      end
    end

    def initialize(arr)
      @arr = arr
    end
    attr_reader :arr

    def to_s
      return @arr.join('.')
    end

    def <=>(other)
      result = @arr.length <=> other.arr.length
      result = @arr <=> other.arr if result == 0
      return result
    end

    def ==(other)
      return false unless other.kind_of?(Revision)
      return @arr == other.arr
    end

    def <(other)
      return (self <=> other) < 0
    end

    def >(other)
      return (self <=> other) > 0
    end

    def <=(other)
      return (self <=> other) <= 0
    end

    def >=(other)
      return (self <=> other) >= 0
    end

    def hash
      return @arr.hash
    end

    def eql?(other)
      return self == other
    end

    def branch_level
      return (@arr.length - 1 ) >> 1
    end

    def branch?
      return false
    end

    def magic_branch?
      return false
    end

    def demagicalize
      return self
    end

    def vendor_branch?
      # Actually, CVS accepts <int>.<int>.<int> as arguments for -b option of
      # `cvs import' but following condition assumes that third integer is odd:
      # <int>.<int>.<odd>.  This assumption is reasonable because the
      # revisions <int>.<int>.<even> may be assigned for non-vendor branches
      # and they cannot be used safely as vendor branches.
      return @arr.length == 3 && (@arr[-1] & 1) == 1
    end

    class NonBranch < Revision
      def next
	arr = @arr.dup
	arr[-1] += 1
	return NonBranch.new(arr)
      end

      def on?(br)
        if br
	  return br.branch? && @arr.length - 1 == br.arr.length && @arr[0...-1] == br.arr
	else
	  return on_trunk?
	end
      end

      def on_trunk?
	return @arr.length == 2
      end

      def branch
	return Branch.new(@arr[0...-1])
      end

      def origin
	raise RevisionError.new("There is no origin of a trunk revision: #{self}") if @arr.length == 2
	return NonBranch.new(@arr[0...-2])
      end
    end

    class Branch < Revision
      def branch?
        return true
      end

      def first
	return NonBranch.new(@arr + [1])
      end

      def origin
	raise RevisionError.new("There is no origin of a trunk: #{self}") if @arr.length == 1
	return NonBranch.new(@arr[0...-1])
      end

      def magicalize
        return Magic.new(@arr)
      end

      class Magic < Branch
	def to_s
	  return @arr[0...-1].join('.') + '.0.' + @arr[-1].to_s
	end

	def magic_branch?
	  return true
	end

	def demagicalize
	  return Branch.new(@arr)
	end
      end
    end
  end
end
