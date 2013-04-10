require 'query/ast/ast_walker'
require 'query/nick_expr'

module Query
  module AST
    class QueryAST
      attr_accessor :context, :context_name, :head, :tail, :filter
      attr_accessor :extra, :summarise, :options, :sorts
      attr_accessor :game_number, :nick, :default_nick, :game
      attr_accessor :group_order, :keys

      def initialize(context_name, head, tail, filter)
        @game = GameContext.game
        @context_name = context_name.to_s
        @context = Sql::QueryContext.named(@context_name)
        @head = head || Expr.and()
        @original_head = @head.dup
        @tail = tail

        @filter = filter
        @options = []
        @opt_map = { }
        @sorts = []
        @keys = Query::AST::KeyedOptionList.new

        @nick = ASTWalker.find(@head) { |node|
          node.nick.value if node.is_a?(NickExpr)
        }

        unless @nick
          @nick = '.'
          @head << ::Query::NickExpr.nick('.')
        end
      end

      def key_value(key)
        self.keys[key]
      end

      def result_prefix_title
        key_value(:title)
      end

      def stub_message(nick)
        stub = self.key_value(:stub)
        return stub if stub

        entities = self.context.entity_name + 's'
        puts "No #{entities} for #{self.description(nick)}."
      end

      def needs_group_order?
        !self.group_order && self.summarise
      end

      def default_group_order
        (extra && extra.default_group_order) ||
          (summarise && summarise.default_group_order)
      end

      def head_desc(suppress_meta=true)
        @original_head.without { |node|
          node.is_a?(Query::NickExpr) || (suppress_meta && node.meta?)
        }.to_s.strip
      end

      def description(default_nick=self.default_nick,
                      options={})
        texts = []
        texts << self.context_name if options[:context]
        texts << (@nick == '.' ? default_nick : @nick).dup
        desc = self.head_desc(!options[:meta])
        if !desc.empty?
          texts << (!options[:no_parens] ? "(#{desc})" : desc)
        end
        texts.join(' ')
      end

      def add_option(option)
        @options << option
        @opt_map[option.name.to_sym] = option
      end

      def option(name)
        @opt_map[name.to_sym]
      end

      def head
        @head ||= Expr.and()
      end

      def summary?
        summarise || (extra && extra.aggregate?) || self.tail
      end

      def has_sorts?
        !@sorts.empty?
      end

      def reverse_sorts!
        @sorts = @sorts.map { |sort| sort.reverse }
      end

      def needs_sort?
        !summary? && !compound_query?
      end

      def primary_sort
        @sorts.first
      end

      def compound_query?
        @tail
      end

      def transform!(&block)
        self.summarise = block.call(self.summarise) if self.summarise
        if self.sorts
          self.sorts = self.sorts.map { |sort|
            block.call(sort)
          }.compact
        end
        self.group_order = block.call(self.group_order) if self.group_order
        self.extra = block.call(self.extra) if self.extra
        self.head = block.call(self.head)
        @full_tail = block.call(@full_tail) if @full_tail
        self.tail = block.call(self.tail) if self.tail
        self
      end

      def transform_nodes!(&block)
        self.map_nodes_as!(:map_nodes, &block)
      end

      def each_node(&block)
        self.summarise.each_node(&block) if self.summarise
        if self.sorts
          self.sorts.each { |sort|
            sort.each_node(&block)
          }
        end
        self.group_order.each_node(&block) if self.group_order
        self.extra.each_node(&block) if self.extra
        self.head.each_node(&block)
        (self.full_tail || self.tail).each_node(&block) if self.tail
        self
      end

      def map_nodes_as!(mapper, *args, &block)
        self.transform! { |tree|
          ASTWalker.send(mapper, tree, *args, &block)
        }
      end

      def with_context(&block)
        self.context.with(&block)
      end

      def bind_tail!
        @full_tail = @tail && @tail.merge(@head)
      end

      def full_tail
        @full_tail
      end

      def to_s
        pieces = [context_name]
        pieces << @nick if @nick
        pieces << head.to_query_string(false)
        pieces << @summarise.to_s if summary?
        pieces << "/" << @tail.to_query_string(false) if @tail
        pieces << "?:" << @filter.to_s if @filter
        pieces.select { |x| !x.empty? }.join(' ')
      end
    end
  end
end
