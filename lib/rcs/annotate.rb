require 'rcs/text'

class RCS
  class AnnotatedLine
    def initialize(line)
      @line = line
      @rev1 = nil
      @rev2 = nil
      @date1 = nil
      @date2 = nil
    end
    attr_reader :line
    attr_accessor :rev1, :rev2, :date1, :date2
  end

  def annotate(target_rev, target_branch=nil)
    unless target_branch
      target_branch = target_rev.branch unless target_rev.on_trunk?
    end

    branch_path = []
    if target_branch
      branch_path << target_branch
      r = target_branch.origin
      until r.on_trunk?
	branch_path << r
        r = r.branch
	branch_path << r
        r = r.origin
      end

      trunk_rev = r
    else
      trunk_rev = target_rev
    end

    target_text = nil
    minrev = @head
    maxrev = @head

    r0 = @head
    d = @delta[r0]
    trunk_text = Text.new(d.text, lambda {|line| AnnotatedLine.new(line)})

    branch_text = trunk_text.dup if @head == trunk_rev
    target_text = trunk_text.dup if @head == target_rev

    while r = d.nextrev
      minrev = r
      d = @delta[r]
      trunk_text.patch!(d.text,
        lambda {|line| # this line exists until r and deleted on r0.
	  line = AnnotatedLine.new(line)
	  if target_branch
	    if target_rev.on_trunk? && target_rev <= r && r0 <= trunk_rev
	      line.rev2 = r
	      line.date2 = @delta[r0].date
	    end
	  else
	    if target_rev <= r
	      line.rev2 = r
	      line.date2 = @delta[r0].date
	    end
	  end
	  line
	},
	lambda {|line| # this line added on r0.
	  if line
	    if target_branch
	      if target_rev.on_trunk? ? r < target_rev : r < trunk_rev
		line.rev1 = r0
		line.date1 = @delta[r0].date
	      end
	    else
	      if r < target_rev
		line.rev1 = r0
		line.date1 = @delta[r0].date
	      end
	    end
	  end
	})
      branch_text = trunk_text.dup if r == trunk_rev
      target_text = trunk_text.dup if r == target_rev
      r0 = r
    end

    if branch_text && !branch_path.empty?
      r0 = trunk_rev
      r = nil
      branch = branch_path.pop
      @delta[r0].branches.each {|r1| r = r1 if r1.on? branch}
      while r
	maxrev = r
        d = @delta[r]
	branch_text.patch!(d.text,
	  lambda {|line| # this line added on r.
	    if target_rev < r
	      false
	    else
	      line = AnnotatedLine.new(line)
	      line.rev1 = r
	      line.date1 = d.date
	      line
	    end
	  },
	  lambda {|line| # this line exists until r0 and deleted on r.
	    if line
	      if target_rev <= r0
	        line.rev2 = r0
		line.date2 = d.date
	      end
	    end
	  })
	target_text = branch_text.dup if r == target_rev
	r0 = r
	r = nil
	if !branch_path.empty? && r0 == branch_path.last
	  branch_path.pop
	  branch = branch_path.pop
	  @delta[r0].branches.each {|r1| r = r1 if r1.on? branch}
	else
	  r = d.nextrev
	end
      end
    end

    target_text.lines.each {|line|
      if line.rev1 == nil
        line.rev1 = minrev
        line.date1 = @delta[minrev].date
      end
      if line.rev2 == nil
        line.rev2 = maxrev
        line.date2 = false
      end
    }

    target_text.lines.each {|line|
      yield line.line, line.date1, line.rev1, @delta[line.rev1].author, line.rev2, line.date2
    }
  end
end

if $0 == __FILE__
  $".push('rcs/annotate')
  require 'rcs'

  require 'runit/testcase'
  require 'runit/cui/testrunner'

  class AnnotateTest < RUNIT::TestCase
    def test_x
      rcs = RCS.new
      rcs.mkrev("a\n", "log", "a1", Time.at(1), 'Exp', RCS::Revision.create("1.1"))
      rcs.mkrev("a\nb\n", "log", "a2", Time.at(2), 'Exp', RCS::Revision.create("1.2"))
      rcs.mkrev("b\nc\n", "log", "a3", Time.at(3), 'Exp', RCS::Revision.create("1.3"))
      result = []
      rcs.annotate(RCS::Revision.create("1.2")) {|line, date1, rev1, author, rev2, date2|
        result << [line, date1, rev1, author, rev2, date2]
      }
      assert_equal(
      [
        ["a\n", Time.at(1), RCS::Revision.create("1.1"), "a1", RCS::Revision.create("1.2"), Time.at(3)],
        ["b\n", Time.at(2), RCS::Revision.create("1.2"), "a2", RCS::Revision.create("1.3"), false]
      ], result)
    end

    def test_maintrunk_revision_with_branch_head
      rcs = RCS.new
      rcs.mkrev("a\nb\nc\nd\n", "log", "a1", t1=Time.at(1), 'Exp', r11=RCS::Revision.create("1.1"))
      rcs.mkrev("a\nb\nc\n", "log", "a2", t2=Time.at(2), 'Exp', r12=RCS::Revision.create("1.2"))
      rcs.mkrev("a\nb\n", "log", "a3", t3=Time.at(3), 'Exp', r13=RCS::Revision.create("1.3"))
      rcs.mkrev("a\n", "log", "a3", t4=Time.at(4), 'Exp', r1321=RCS::Revision.create("1.3.2.1"))
      rcs.mkrev("", "log", "a4", t5=Time.at(5), 'Exp', r14=RCS::Revision.create("1.4"))

      result = []
      rcs.annotate(r12, r1321.branch) {|line, date1, rev1, author, rev2, date2|
        result << [line, date1, rev1, author, rev2, date2]
      }
      assert_equal(
      [
        ["a\n", t1, r11, "a1", r1321, false],
        ["b\n", t1, r11, "a1", r13, t4],
        ["c\n", t1, r11, "a1", r12, t3]
      ], result)
    end
  end

  RUNIT::CUI::TestRunner.run(AnnotateTest.suite)
end
