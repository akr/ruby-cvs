class CVS
  class C < CVS
    class D < CVS::D
    end

    class F < CVS::F
      def self.read(f)
	gen = Generator.new
        f.parse_rcs(gen)
      end

      class Delta
      end

      class Generator < Visitor
	def initialize
	  @tags = []
	  @delta = []
	end

        def admin(hash)
	  @admin = hash
	end

	def head(rev)
	  @head = rev
	end

	def branch(rev)
	  @branch = rev
	end

	def symbol(tag, rev)
	  @tags << [tag, rev]
	end

	def delta(rev, hash)
	  @date = hash['date']
	  @author = hash['author']
	  @state = hash['state']
	  @branches = hash['branches']
	  @next = hash['next']
	end

	def description(desc)
	  @description = desc
	end

	def deltatext(rev, log, hash, text)
	  p [rev, log, hash, text]
	end
      end
    end
  end
end
