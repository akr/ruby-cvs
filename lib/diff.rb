require 'thread'

class Diff
  def Diff.diff(a, b)
    #return cdiff(a, b)
    #return npdiff(a, b)
    return diff2(Data.new(a, b))
  end

  def Diff.diff2(data)
    result = nil
    # Try speculative execution.

    tg = ThreadGroup.new

    # Since NPDiff is faster than ContoursDiff if two sequences are very similar,
    # try it first.
    tg.add(Thread.new {
      #print "NPDiff start.\n"
      result = NPDiff.new(data).diff
      Thread.exclusive {tg.list.each {|t| t.kill if t != Thread.current}}
      #print "NPDiff win.\n"
    })

    # start ContoursDiff unless NPDiff is already ended with first quantum, 
    tg.add(Thread.new {
      #print "ContoursDiff start.\n"
      result = ContoursDiff.new(data).diff
      Thread.exclusive {tg.list.each {|t| t.kill if t != Thread.current}}
      #print "ContoursDiff win.\n"
    }) unless tg.list.empty?

    tg.list.each {|t| t.join}

    return result
  end

  def Diff.cdiff(a, b)
    return ContoursDiff.new(Data.new(a, b)).diff
  end

  def Diff.npdiff(a, b)
    return NPDiff.new(Data.new(a, b)).diff
  end

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
  class Data
    def initialize(a, b)
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

    attr_reader :alphabet, :a, :b

    def diff(lcs)
      result = []
      @prefix.each {|v| result << [:com, *v]}

      i0 = j0 = 0
      lcs.each {|i, j|
	i = @revert_index_a[i]
	j = @revert_index_b[j]
	while i0 < i
	  result << [:del, @middle_a[i0], nil]
	  i0 += 1
	end

	while j0 < j
	  result << [:add, nil, @middle_b[j0]]
	  j0 += 1
	end

	result << [:com, @middle_a[i], @middle_b[j]]
	i0 += 1
	j0 += 1
      }
      i = @middle_a.length
      j = @middle_b.length

      while i0 < i
	result << [:del, @middle_a[i0], nil]
	i0 += 1
      end

      while j0 < j
	result << [:add, nil, @middle_b[j0]]
	j0 += 1
      end

      @suffix.each {|v| result << [:com, *v]}
      return result
    end

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


=begin
== ContourDiff
ContourDiff is based on the algorithm which is presented by Claus Rick.

I made two optimizations (for long LCS):

* When midpoint of LCS is found, adjacent matches on same diagonal is checked.
  They are also part of LCS.  If LCS is long, they may exist and even long.

* Search method for next contour uses divide and conquer.

  * Search region is rectangle: (This is forward contour case.)

    (min{i|(i,j) in dominants}, min{j|(i,j) in dominants}) to (end_a, end_b).

  * In search region (i0,j0) to (i1,j1), For each dominant match (i,j) in
    Ck and the region, (i+1,j+1) is checked first.  If LCS is long it is
    match frequently.
    If it is match, it's a match in Ck+1 and it divides search region:
    
    (i0,j) to (i+1,end_b)
    (i,j0) to (end_a,j+1)

  * For each divided region, dominants is searchd line by line:
    topmost row or leftmost column.  Longer one is selected.

    If no dominant match is found in the line,
    search region is reduced with only the line.

    If a dominant match is found in the line,
    search region is reduced with the line and
    rectangle farer than the match.

== References
[Claus2000] Claus Rick,
Simple and Fast Linear Space Computation of Longest Common Subsequences,
Information Processing Letters, Vol. 75/6, 275 - 281,
Elsevier (2000)

[Claus1995] Claus Rick,
A New Flexible Algorithm for the Longest Common Subsequence Problem,
Proceedings of the 6th Symposium on Combinatorial Pattern Matching (CPM'95),
Lecture Notes in Computer Science, Vol. 937, 340 - 351,
Springer Verlag (1995)
Also in Nordic Journal of Computing (NJC), Vol. 2, No. 4, Winter 1995, 444 - 461.
http://web.informatik.uni-bonn.de/IV/Mitarbeiter/rick/lcs.dvi.Z
=end
  class ContoursDiff
    def initialize(data)
      @data = data
      @a = data.a
      @b = data.b
      @closest_a = Closest.new(@data.alphabet.size, @a)
      @closest_b = Closest.new(@data.alphabet.size, @b)
    end

    def diff(&proc)
      @data.diff(lcs, &proc)
    end

    def lcs(beg_a=0, beg_b=0, end_a=@a.length, end_b=@b.length, len=nil, lcs=[])
      #p [:lcs, beg_a, beg_b, end_a, end_b]
      found, len, mid_a, mid_b = midpoint(beg_a, beg_b, end_a, end_b, len)

      return lcs unless found

      len1 = len2 = len / 2
      if len & 1 == 0
	len2 -= 1
      end

      l = 1

      while beg_a < mid_a && beg_b < mid_b && @a[mid_a-1] == @b[mid_b-1]
	len1 -= 1
        mid_a -= 1
	mid_b -= 1
	l += 1
      end

      while mid_a+l < end_a && mid_b+l < end_b && @a[mid_a+l] == @b[mid_b+l]
	len2 -= 1
	l += 1
      end

      lcs(beg_a, beg_b, mid_a, mid_b, len1, lcs)
      l.times {|i| lcs << [mid_a+i, mid_b+i]}
      lcs(mid_a + l, mid_b + l, end_a, end_b, len2, lcs)

      return lcs
    end

    def midpoint(beg_a, beg_b, end_a, end_b, len)
      return false, 0, nil, nil if len == 0

      fc = newForwardContour(beg_a, beg_b, end_a, end_b)
      return false, 0, nil, nil if fc.empty?

      bc = newBackwardContour(beg_a, beg_b, end_a, end_b)

      midpoints = nil

      l = 1

      while true
	crossed = contourCrossed(fc, bc)
	if crossed
	  midpoints = fc
	  break
	end
	l += 1
	fc = nextForwardContour(fc, end_a, end_b)
	crossed = contourCrossed(fc, bc)
	if crossed
	  midpoints = bc
	  break
	end
	l += 1
	bc = nextBackwardContour(bc, beg_a, beg_b)
      end

      # select a dominant match which is closest to diagonal.
      m = midpoints[0]
      (1...midpoints.length).each {|m1| m = m1 if m[0] < m1[0] && m[1] < m1[1] }

      return [true, l, *m]
    end

    def newForwardContour(beg_a, beg_b, end_a, end_b)
      return nextForwardContour([[beg_a-1,beg_b-1]], end_a, end_b)
    end

    def nextForwardContour(fc0, end_a, end_b)
      next_dominants = []
      topright_dominant = 0
      bottomleft_dominant = fc0.length - 1

      fc0.each_index {|k|
	i, j = fc0[k]
	if i+1 < end_a && j+1 < end_b && @a[i+1] == @b[j+1]
	  if topright_dominant <= k - 1
	    nextForwardContour1(fc0, topright_dominant, k - 1, i+1, end_b, next_dominants)
	  end
	  next_dominants << [i+1, j+1]
	  end_b = j+1
	  topright_dominant = k + 1
	end
      }

      if topright_dominant <= bottomleft_dominant
	nextForwardContour1(fc0, topright_dominant, bottomleft_dominant, end_a, end_b, next_dominants)
      end
      return next_dominants
    end

    def nextForwardContour1(fc0, topright_dominant, bottomleft_dominant, end_a, end_b, next_dominants_topright)
      beg_a = fc0[topright_dominant][0] + 1
      beg_b = fc0[bottomleft_dominant][1] + 1

      next_dominants_bottomleft = []

      while beg_a < end_a && beg_b < end_b
	if end_a - beg_a < end_b - beg_b
	  # search top row: [beg_a, beg_b] to [beg_a, end_b-1] inclusive
	  if topright_dominant + 1 < fc0.length && fc0[topright_dominant + 1][0] < beg_a
	    topright_dominant += 1
	  end
	  search_start_b = fc0[topright_dominant][1]
	  # search top row: [beg_a, search_start_b+1] to [beg_a, end_b-1] inclusive
	  j = @closest_b.next(@a[beg_a], search_start_b)
	  if j < end_b
	    # new dominant found.
	    # it means that the rectangle [beg_a, j] to [end_a-1, end_b-1] is not required to search any more.
	    next_dominants_topright << [beg_a, j]
	    end_b = j
	  end
	  beg_a += 1
	else
	  # search left column: [beg_a, beg_b] to [end_a-1, beg_b]
	  if 0 <= bottomleft_dominant - 1 && fc0[bottomleft_dominant - 1][1] < beg_b
	    bottomleft_dominant -= 1
	  end
	  search_start_a = fc0[bottomleft_dominant][0]
	  # search left column: [search_start_a, beg_b] to [end_a-1, beg_b]
	  i = @closest_a.next(@b[beg_b], search_start_a)
	  if i < end_a
	    # new dominant found.
	    # if means that the rectangle [i, beg_b] to [end_a-1, end_b-1] is not required to search any more.
	    next_dominants_bottomleft << [i, beg_b]
	    end_a = i
	  end
	  beg_b += 1
	end
      end

      next_dominants_bottomleft.reverse!
      next_dominants_topright.concat next_dominants_bottomleft
    end

    def newBackwardContour(beg_a, beg_b, end_a, end_b)
      return nextBackwardContour([[end_a,end_b]], beg_a, beg_b)
    end

    def nextBackwardContour(bc0, beg_a, beg_b)
      next_dominants = []
      topright_dominant = 0
      bottomleft_dominant = bc0.length - 1

      bc0.each_index {|k|
	i, j = bc0[k]
	if beg_a <= i-1 && beg_b <= j-1 && @a[i-1] == @b[j-1]
	  if topright_dominant <= k - 1
	    nextBackwardContour1(bc0, topright_dominant, k - 1, beg_a, j, next_dominants)
	  end
	  next_dominants << [i-1, j-1]
	  beg_a = i
	  topright_dominant = k + 1
	end
      }

      if topright_dominant <= bottomleft_dominant
	nextBackwardContour1(bc0, topright_dominant, bottomleft_dominant, beg_a, beg_b, next_dominants)
      end
      return next_dominants
    end

    def nextBackwardContour1(bc0, topright_dominant, bottomleft_dominant, beg_a, beg_b, next_dominants_topright)
      end_a = bc0[bottomleft_dominant][0]
      end_b = bc0[topright_dominant][1]

      next_dominants_bottomleft = []

      while beg_a < end_a && beg_b < end_b
	if end_a - beg_a < end_b - beg_b
	  # search bottom row: [end_a-1, end_b-1] from [end_a-1, beg_b]
	  if 0 <= bottomleft_dominant - 1 && end_a - 1 < bc0[bottomleft_dominant - 1][0]
	    bottomleft_dominant -= 1
	  end
	  search_end_b = bc0[bottomleft_dominant][1]
	  # search bottom row: [end_a-1, search_end_b-1] from [end_a-1, beg_b]
	  j = @closest_b.prev(@a[end_a-1], search_end_b)
	  if beg_b <= j
	    # new dominant found.
	    # it means that the rectangle [beg_a, beg_b] to [end_a-1, j] is not required to search any more.
	    next_dominants_bottomleft << [end_a-1, j]
	    beg_b = j + 1
	  end
	  end_a -= 1
	else
	  # search right column: [end_a-1, end_b-1] to [beg_a, end_b-1]
	  if topright_dominant + 1 < bc0.length && end_b - 1 < bc0[topright_dominant + 1][1]
	    topright_dominant += 1
	  end
	  search_end_a = bc0[topright_dominant][0]
	  # search right column: [search_end_a-1, end_b-1] to [beg_a, end_b-1]
	  i = @closest_a.prev(@b[end_b-1], search_end_a)
	  if beg_a <= i
	    # new dominant found.
	    # if means that the rectangle [beg_a, beg_b] to [i, end_b-1] is not required to search any more.
	    next_dominants_topright << [i, end_b-1]
	    beg_a = i + 1
	  end
	  end_b -= 1
	end
      end

      next_dominants_bottomleft.reverse!
      next_dominants_topright.concat next_dominants_bottomleft
    end

    def contourCrossed(fc, bc)
      #p [:contourCrossed1Beg, fc, bc]
      new_fc, new_bc = contourCrossed1(fc, bc)
      #p [:contourCrossed1End, new_fc, new_bc]
      if new_fc.empty? && new_bc.empty?
	return true
      end

      fc.replace new_fc
      bc.replace new_bc

      return false
    end

    def contourCrossed1(fc, bc)
      new_fc = []
      new_bc = []
      fc_k = 0
      bc_k = 0
      bc_j = bc[0][1]
      fc_j = fc[0][1]
      fc_j = bc_j if fc_j < bc_j
      fc_j += 1
      while fc_k < fc.length || bc_k < bc.length
	if bc_k < bc.length && (!(fc_k < fc.length) || bc[bc_k][0] <= fc[fc_k][0])
	  if fc_j < bc[bc_k][1]
	    new_bc << bc[bc_k]
	  end
	  bc_k += 1
	  bc_j = bc_k < bc.length ? bc[bc_k][1] : 0
	end

	if fc_k < fc.length && (!(bc_k < bc.length) || fc[fc_k][0] < bc[bc_k][0])
	  if fc[fc_k][1] < bc_j
	    new_fc << fc[fc_k]
	  end
	  fc_j = fc[fc_k][1]
	  fc_k += 1
	end
      end
      return new_fc, new_bc
    end

    class Closest
      def initialize(symnum, arr)
	@table = Array.new(symnum)
	@table.each_index {|s| @table[s] = [-1]}
	arr.each_index {|i| @table[arr[i]] << i}
	@n = arr.length + 1
	@table.each_index {|s| @table[s] << @n}
      end

      def next(s, i)
	t = @table[s]

	if t.length < 10
	  t.each {|j| return j if i < j}
	  return @n
	end

	lower  = -1
	upper = t.length
	while lower + 1 != upper
	  mid = (lower + upper) / 2
	  if t[mid] <= i
	    lower = mid
	  else 
	    upper = mid
	  end
	end
	b = lower + 1

	if b < t.length
	  return t[b]
	else
	  return @n
	end

      end

      def prev(s, i)
	t = @table[s]

	if t.length < 10
	  t.reverse_each {|j| return j if j < i}
	  return -1
	end

	lower  = -1
	upper = t.length
	while lower + 1 != upper
	  mid = (lower + upper) / 2
	  if t[mid] < i
	    lower = mid
	  else 
	    upper = mid
	  end
	end
	if 0 < upper
	  return t[upper - 1]
	else
	  return -1
	end
      end
    end
  end

=begin
NPDiff uses the algorithm described in following paper.

[Wu1990] Sun Wu, Udi Manber, Gene Myers and Webb Miller,
An O(NP) Sequence Comparison Algorithm,
Information Processing Letters 35, 1990, 317-323
=end
  class NPDiff
    def initialize(data)
      if data.a.length > data.b.length
	@data = data
	@a = data.b
	@b = data.a
	@exchanged = true
      else
	@data = data
	@a = data.a
	@b = data.b
	@exchanged = false
      end
    end

    def diff(&proc)
      @data.diff(lcs, &proc)
    end

    def lcs
      @m = @a.length
      @n = @b.length
      d = @n - @m
      fp = Array.new(@n+1+@m+1+1, -1)
      fp_base = -(@m+1)
      path = Array.new(fp.length)
      p = -1
      begin
        p += 1
	(-p).upto(d-1) {|k|
	  a = fp[fp_base+k-1]+1
	  b = fp[fp_base+k+1]
	  if a < b
	    y = fp[fp_base+k] = snake(k, b)
	    path[fp_base+k] = path[fp_base+k+1]
	    path[fp_base+k] = [y - k, y, y - b, path[fp_base+k]] if b < y
	  else
	    y = fp[fp_base+k] = snake(k, a)
	    path[fp_base+k] = path[fp_base+k-1]
	    path[fp_base+k] = [y - k, y, y - a, path[fp_base+k]] if a < y
	  end
	}
	(d+p).downto(d+1) {|k|
	  a = fp[fp_base+k-1]+1
	  b = fp[fp_base+k+1]
	  if a < b
	    y = fp[fp_base+k] = snake(k, b)
	    path[fp_base+k] = path[fp_base+k+1]
	    path[fp_base+k] = [y - k, y, y - b, path[fp_base+k]] if b < y
	  else
	    y = fp[fp_base+k] = snake(k, a)
	    path[fp_base+k] = path[fp_base+k-1]
	    path[fp_base+k] = [y - k, y, y - a, path[fp_base+k]] if a < y
	  end
	}
	a = fp[fp_base+d-1]+1
	b = fp[fp_base+d+1]
	if a < b
	  y = fp[fp_base+d] = snake(d, b)
	  path[fp_base+d] = path[fp_base+d+1]
	  path[fp_base+d] = [y - d, y, y - b, path[fp_base+d]] if b < y
	else
	  y = fp[fp_base+d] = snake(d, a)
	  path[fp_base+d] = path[fp_base+d-1]
	  path[fp_base+d] = [y - d, y, y - a, path[fp_base+d]] if a < y
	end
      end until fp[fp_base+d] == @n
      shortest_path = path[fp_base+d]
      lcs = []
      while shortest_path
        x, y, l, shortest_path = shortest_path
	l.times {|i| lcs << [x-i-1,y-i-1]}
      end
      lcs.reverse!
      lcs.collect {|xy| tmp = xy[0]; xy[0] = xy[1]; xy[1] = tmp} if @exchanged
      return lcs
    end

    def snake(k, y)
      x = y - k
      while x < @m && y < @n && @a[x] == @b[y]
        x += 1
	y += 1
      end
      return y
    end
  end
end

if __FILE__ == $0
  require 'runit/testcase'
  require 'runit/cui/testrunner'

  class DiffTest < RUNIT::TestCase
    def lcs_len(diff)
      l = 0
      diff.each {|type, s, d| l += 1 if type == :com}
      return l
    end

    def src(diff)
      result = []
      diff.each {|type, s, d| result << s if type != :add}
      return result
    end

    def dst(diff)
      result = []
      diff.each {|type, s, d| result << d if type != :del}
      return result
    end

    def try1(l, a, b)
      diff = @diff_class.new(Diff::Data.new(a.split(//), b.split(//))).diff
      assert_equal(l, lcs_len(diff))
      assert_equal(a, src(diff).join)
      assert_equal(b, dst(diff).join)
    end

    def try2(l, a, b)
      try1 l, a, b
      try1 l, b, a
    end

    def test_abacbcba_cbabbacac # [Claus2000]
      try2 5, "abacbcba", "cbabbacac"
    end

    def test_cbabac_abcabba # [Myers1986]
      try2 4, "cbabac", "abcabba"
    end

    def test_acbdeacbed_acebdabbabed # [Wu1990]
      try2 8, "acbdeacbed", "acebdabbabed"
    end

    def test_emptybottle_nematodeknowledge # http://www.ics.uci.edu/~eppstein/161/960229.html
      try2 7, "empty bottle", "nematode knowledge"
    end

    def test_bddcddbddaacdbca_ccbdcdadccbabddd # [Michael94]
      try2 9, "bddcddbddaacdbca", "ccbdcdadccbabddd"
    end

    def test_az_za
      try2 1, "abcdefghijklmnopqrstuvwxyz", "zyxwvutsrqponmlkjihgfedcba"
    end

    def test_abcd_acbd
      try2 3, "abcd", "acbd"
    end
  end

  class ContoursDiffTest < DiffTest
    def setup
      @diff_class = Diff::ContoursDiff
    end
  end

  class NPDiffTest < DiffTest
    def setup
      @diff_class = Diff::NPDiff
    end
  end

  RUNIT::CUI::TestRunner.run(ContoursDiffTest.suite)

  RUNIT::CUI::TestRunner.run(NPDiffTest.suite)
end

