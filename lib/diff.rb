=begin
= Diff
--- Diff.new(seq_a, seq_b)
--- Diff#ses([algorithm=:speculative])
--- Diff#lcs([algorithm=:speculative])

    Available algorithms are follows.
    * :shortestpath
    * :contours
    * :speculative

= Diff::EditScript
--- Diff::EditScript.new
--- Diff::EditScript#del(seq_or_len_a)
--- Diff::EditScript#add(seq_or_len_b)
--- Diff::EditScript#common(seq_or_len_a[, seq_or_len_b])
--- Diff::EditScript#commonsubsequence
--- Diff::EditScript#count_a
--- Diff::EditScript#count_b
--- Diff::EditScript#additions
--- Diff::EditScript#deletions
--- Diff::EditScript#each {|mark, a, b| ...}
--- Diff::EditScript#apply(arr)
--- Diff::EditScript.parse_rcsdiff(input)
--- Diff::EditScript#rcsdiff([out=''])

= Diff::Subsequence
--- Diff::Subsequence.new
--- Diff::Subsequence.add(i, j[, len=1])
--- Diff::Subsequence#length
--- Diff::Subsequence#each {|i, j, len| ...}
=end

require 'diff/editscript'
require 'diff/subsequence'
require 'diff/shortestpath'
require 'diff/contours'
require 'diff/speculative'

=begin
Data class reduces input for diff and convert alphabet to Integer.

It reduces input by removing common prefix, suffix and
unique elements.

So, reduced input has following properties:
* First element is different.
* Last element is different.
* Any elemnt in A is also exist in B.
* Any elemnt in B is also exist in A.

=end
class Diff
  def initialize(a, b)
    @original_a = a
    @original_b = b

    a = a.dup
    b = b.dup

    @suffix = []
    while !a.empty? && !b.empty?
      if a.last.hash == b.last.hash && a.last.eql?(b.last)
	@suffix << [a.last, b.last]
	a.pop
	b.pop
      else
	break
      end
    end
    @suffix.reverse!

    @prefix = []
    i = 0
    while i < a.length && i < b.length
      if a[i].hash == b[i].hash && a[i].eql?(b[i])
	@prefix << [a[i], b[i]]
	i += 1
      else
	break
      end
    end
    a[0, i] = []
    b[0, i] = []

    @middle_a = a
    @middle_b = b

    hash_a = {}
    hash_b = {}
    a.each {|v| hash_a[v] = true}
    b.each {|v| hash_b[v] = true}

    reduced_a = []
    reduced_b = []
    @revert_index_a = []
    @revert_index_b = []

    a.each_index {|i|
      v = a[i]
      if hash_b.include? v
	reduced_a << v
	@revert_index_a << i
      end
    }

    b.each_index {|i|
      v = b[i]
      if hash_a.include? v
	reduced_b << v
	@revert_index_b << i
      end
    }

    @alphabet = Alphabet.new
    @a = []; reduced_a.each {|v| @a << @alphabet.add(v)}
    @b = []; reduced_b.each {|v| @b << @alphabet.add(v)}
  end

  def Diff.algorithm(algorithm)
    case algorithm
    when :shortestpath
      return ShortestPath
    when :contours
      return Contours
    when :speculative
      return Speculative
    else
      raise ArgumentError.new("unknown diff algorithm: #{algorithm}")
    end
  end

  def lcs(algorithm=:speculative) # longest common subsequence
    klass = Diff.algorithm(algorithm)
    reduced_lcs = klass.new(@a, @b).lcs

    lcs = Subsequence.new
    lcs.add 0, 0, @prefix.length if 0 < @prefix.length
    reduced_lcs.each {|i, j, l|
      l.times {|k|
        lcs.add @revert_index_a[i+k], @revert_index_b[j+k]
      }
    }
    lcs.add @prefix.length + @middle_a.length, @prefix.length + @middle_a.length, @suffix.length if 0 < @suffix.length

    return lcs
  end

  def ses(algorithm=:speculative) # shortest edit script
    lcs = lcs(algorithm)
    ses = EditScript.new
    i0 = j0 = 0
    lcs.each {|i, j, l|
      ses.del @original_a[i0, i - i0] if i0 < i
      ses.add @original_b[j0, j - j0] if j0 < j
      ses.common @original_a[i, l], @original_b[j, l]

      i0 = i + l
      j0 = j + l
    }

    i = @original_a.length
    j = @original_b.length
    ses.del @original_a[i0, i - i0] if i0 < i
    ses.add @original_b[j0, j - j0] if j0 < j

    return ses
  end

  class Alphabet
    def initialize
      @hash = {}
    end

    def add(v)
      if @hash.include? v
	return @hash[v]
      else
	return @hash[v] = @hash.size
      end
    end

    class NoSymbol < StandardError
    end
    def index(v)
      return @hash.fetch {raise NoSymbol.new(v.to_s)}
    end

    def size
      return @hash.size
    end
  end
end
