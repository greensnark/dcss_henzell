require 'sql/query_table'
require 'sql/table_set'
require 'set'

module Sql
  # Tracks the set of tables referenced in a query with one primary table
  # and any number of additional join tables.
  class QueryTables
    attr_reader :primary_table, :outer_table, :joins
    attr_accessor :tables

    def self.next_id
      @@id ||= 0
      @@id += 1
    end

    def initialize(query_ast, primary_table, outer_table)
      @id = self.class.next_id
      @query_ast = query_ast
      @primary_table = Sql::QueryTable.table(primary_table)
      @outer_table = outer_table

      # Share a set of tables with the outer table if possible.
      @tables = (@outer_table && @outer_table.query_tables.tables) || TableSet.new
      @joins = []
    end

    def initialize_copy(other)
      super
      @id = self.class.next_id
      @joins = @joins.dup
    end

    def rebind_table(old_table, new_table)
      @tables.rebind(old_table, new_table)
      @joins.each { |j|
        j.rebind_table(old_table, new_table)
      }
    end

    def size
      @tables.size
    end

    def lookup!(table)
      return lookup!(primary_table) if table.equal?(@query_ast)
      @tables.lookup!(table)
    end

    def find_join(join_condition)
      @joins.find { |j|
        j.tables_match?(join_condition)
      }
    end

    def register_table(table, force_new_alias=false)
      raise("Cannot register outer table (#{outer_table}) in subquery #{@query_ast} (primary:#{@primary_table})") if table == outer_table
      @tables.register_table(table, force_new_alias)
    end

    def [](table_alias)
      @tables[table_alias]
    end

    def table(table_name)
      @tables.table(table_name)
    end

    def join(join_condition)
      join_with(join_condition) { |joins|
        joins << join_condition
      }
    end

    ##
    # Returns the table name and joins, suitable for the FROM clause
    # of a query.
    def to_sql
      sort_join_conditions!
      sql_frags = []
      if !@joins.empty?
        include_left_table = true
        seen_tables = Set.new
        for join in @joins
          if !include_left_table && !seen_tables.include?(join.left_table)
            if seen_tables.include?(join.right_table)
              join.flip!
            else
              raise("Bad join condition: #{join}: references table that's not in the list of priors: #{seen_tables.to_a.map(&:to_s)}")
            end
          end

          sql_frags << join.to_sql(include_left_table)

          seen_tables << join.left_table if include_left_table
          seen_tables << join.right_table
          include_left_table = false
        end
      else
        sql_frags = [primary_table.to_sql]
      end
      sql_frags.join("\n ")
    end

    ##
    # Returns any SQL ? placeholder values from JOINed subqueries.
    def sql_values
      values = []
      include_left_table = true
      @joins.each { |j|
        values += j.sql_values(include_left_table)
        include_left_table = false
      }
      values
    end

    def to_s
      "QueryTables[##{@id} #{@tables.map(&:name).join(',')}]"
    end

    private

    # Reorder join conditions so that each join refers to one of the tables in
    # one of the prior joins.
    def sort_join_conditions!
      return if @joins.empty?

      seen_tables = Set.new
      unsorted_joins = @joins.dup
      sorted_joins = [unsorted_joins.shift]
      seen_tables << sorted_joins.first.left_table
      seen_tables << sorted_joins.first.right_table
      until unsorted_joins.empty?
        next_join_condition = find_next_join_condition(seen_tables, unsorted_joins)
        unless next_join_condition
          require 'pry'
          binding.pry
          raise("Bad join condition chain: no condition in #{unsorted_joins.map(&:to_s)} matches the table set #{seen_tables.to_a.map(&:to_s)}")
        end
        sorted_joins << next_join_condition
        seen_tables << next_join_condition.left_table
        seen_tables << next_join_condition.right_table
      end
      @joins = sorted_joins
    end

    def find_next_join_condition(table_set, join_list)
      found_join_condition = join_list.find { |j|
        table_set.include?(j.left_table) || table_set.include?(j.right_table)
      }
      return nil unless found_join_condition

      join_list.delete(found_join_condition)
      unless table_set.include?(found_join_condition.left_table)
        found_join_condition.flip!
      end
      found_join_condition
    end

    def join_with(join_condition)
      if @joins.include?(join_condition)
        update_join_table_aliases(join_condition)
        return
      end

      register_table(join_condition.left_table)
      register_table(join_condition.right_table, :force_new_alias)

      yield @joins

      self
    end

    def update_join_table_aliases(join)
      existing_join = @joins.find { |j| j == join }
      join.left_table.alias = existing_join.left_table.alias
      join.right_table.alias = existing_join.right_table.alias
    end
  end
end
