require 'tpl/template'
require 'cmd/executor'

class LearnDBQuery
  def self.query(db, scope, query, index=nil)
    if index.nil?
      query, index = self.parse_query(query)
    end

    self.new(db, scope, query, index, { }).query
  end

  def self.parse_query(query)
    if query =~ /^(.*)\[([+-]?\d+)\]\s*$/
      [$1, $2.to_i]
    else
      [query, 1]
    end
  end

  attr_reader :db, :scope, :term, :index, :visited
  def initialize(db, scope, term, index, visited)
    @db = db
    @scope = scope
    @term = term
    @index = index
    @visited = visited
  end

  def visited?(term, index=1)
    visited[key(term, index)]
  end

  def key(term, index)
    "#{term}||#{index}"
  end

  def mark_visited!(term, index)
    visited[key(term, index)] = true
  end

  def query
    mark_visited!(term, index)

    entry = @db.entry(term)
    lookup = entry[index]

    if index == -1 || (!lookup && index != 1)
      result = full_entry_redirect(entry)
      return result if result || index != -1
    end

    resolve(lookup) if lookup
  end

  ##
  # Given a term A that redirects to another term B as its first
  # entry, A[x] should behave the same as B[x] for queries. This function
  # attempts to follow the redirect as term(A[1])[x] if A[x] returns nothing.
  def full_entry_redirect(entry)
    first_item = entry[1]
    return nil unless first_item
    match = redirect?(first_item)
    return nil unless match
    pattern = match[1]
    new_term, new_index = self.class.parse_query(pattern)
    return nil if new_index != 1
    follow_redirect(new_term, index)
  end

  def follow_redirect(new_term, new_index)
    return nil if visited?(new_term, new_index)
    self.class.new(db, scope, new_term, new_index, visited).query
  end

  def redirect?(result)
    /^\s*see\s+\{(.*)\}\s*$/i.match(result.text)
  end

  def resolve(result)
    if redirect?(result)
      result = resolve_redirect(result)
    end

    command = redirect_pattern(result)
    if command
      command_res = command_eval(result, command)
      return command_res if command_res
    end

    if result.text =~ /^\s*do\s+\{(.*)\}\s*$/i
      command_res = command_eval(result, $1)
      return command_res if command_res
    end

    LearnDB::LookupResult.new(result.entry, result.index, result.size,
      Tpl::Template.template_eval(result.text, scope))
  end

  def command_eval(result, command)
    LearnDB::LookupResult.new(result.entry, result.index, result.size,
      Tpl::Template.subcommand_eval(command, scope), true)
  rescue Cmd::UnknownCommandError
    nil
  end

  def redirect_pattern(result)
    match = redirect?(result)
    match && match[1]
  end

  def resolve_redirect(result)
    visited ||= { }
    current = result
    pattern = redirect_pattern(result)
    return result unless pattern
    new_term, new_index = self.class.parse_query(pattern)
    follow_redirect(new_term, new_index) || result
  end
end