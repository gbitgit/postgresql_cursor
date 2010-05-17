gem 'activerecord', '<=2.3.5'
require 'active_record'

# Class to operate a PostgreSQL cursor to buffer a set of rows, and return single rows for processing.
# Use this class when processing a very large number of records, which would otherwise all be instantiated
# in memory by find(). This also adds helpers to ActiveRecord::Base for *find_with_cursor()* and 
# *find_by_sql_with_cursor()* to return instances of the cursor ready to fetch. 
#
# Use each() with a block to accept an instance of the Model (or whatever you define with a block on 
# initialize()). It will open, buffer, yield each row, then close the cursor.
#
# PostgreSQL requires that a cursor is executed within a transaction block, which you must provide unless
# you use each() to run through the result set.
class PostgreSQLCursor
  attr_reader :count, :buffer_reads
  @@counter=0
  
  # Define a new cursor, with a SQL statement, as a string with parameters already replaced, and options for 
  # the cursor
  # * :buffer_size=>number of records to buffer, default 10000.
  # Pass a optional block which takes a Hash of "column"=>"value", and returns an object to be yielded for each row.
  def initialize(sql,*args, &block)
    @options = args.last.is_a?(Hash) ? args.pop : {}
    @@counter += 1
    @instantiator = block || lambda {|r| r }
    @sql = sql
    @name = "pgcursor_#{@@counter}"
    @connection = ActiveRecord::Base.connection
    @buffer_size = @options[:buffer_size] || 10_000 
    @count = 0
    @state = :ready
  end
  
  # Iterates through the rows, yields them to the block. It wraps the processing in a transaction 
  # (required by PostgreSQL), opens the cursor, buffers the results, returns each row, and closes the cursor.
  def each
    @connection.transaction do
      @result = open_cursor
      while (row = fetch_cursor) do
        yield row
      end
      close_cursor
      @count
    end
  end
  
  # Starts buffered result set processing for a given SQL statement. The DB
  def open_cursor
    raise "Open Cursor state not ready" unless @state == :ready
    #@sql = replace_params(*(@sql.flatten)) if @sql.is_a?(Array)
    #@connection.start_transaction if @connection.outside_transaction?
    @result = @connection.execute("declare #{@name} cursor for #{@sql}")
    @state = :empty
    @buffer_reads = 0
    @buffer = nil
  end

  # Returns a string of the current status
  def status #:nodoc:
    "row=#{@count} buffer=#{@buffer.size} state=#{@state} buffer_size=#{@buffer_size} reads=#{@buffer_reads}"
  end

  # Fetches the next block of rows into memory
  def fetch_buffer #:nodoc:
    return unless @state == :empty
    @result = @connection.execute("fetch #{@buffer_size} from #{@name}")
    @buffer = @result.collect {|row| row }
    @state  = @buffer.size > 0 ? :buffered : :eof
    @buffer_reads += 1
    #puts self.status
    @buffer
  end

  # Returns the next row from the cursor, or nil when end of data.
  # The row returned is a hash[:colname]
  def fetch_cursor
    open_cursor  if @state == :ready
    fetch_buffer if @state == :empty
    return nil   if @state == :eof || @state == :closed
    @state = :empty if @buffer.size <= 1
    @count+= 1
    row = @buffer.shift
    #row.is_a?(Hash) ? row.symbolize_keys : row
    @instantiator.call(row)
  end
  
  alias_method :next, :fetch_cursor
  
  # Closes the cursor to clean up resources. Call this method during process of each() to 
  # exit the loop
  def close_cursor
    pg_result = @connection.execute("close #{@name}")
    @state = :closed
  end
  
end

class ActiveRecord::Base
  class <<self
  
    # Returns a PostgreSQLCursor instance to access the results, on which you are able to call
    # each (though the cursor is not Enumerable and no other methods are available).
    # No :all argument is needed, and other find() options can be specified.
    # Specify the :cursor=>{...} option to override options for the cursor such has :buffer_size=>n.
    # Pass an optional block that takes a Hash of the record and returns what you want to return.
    # For example, return the Hash back to process a Hash instead of a table instance for better speed.
    def find_with_cursor(*args, &block)
      find_options = args.last.is_a?(Hash) ? args.pop : {}
      options = find_options.delete(:cursor) || {}
      validate_find_options(find_options)
      set_readonly_option!(find_options)
      sql = construct_finder_sql(find_options)
      PostgreSQLCursor.new(sql, options) { |r| block_given? ? yield(r) : instantiate(r) }
    end
  
    # Returns a PostgreSQLCursor instance to access the results of the sql
    # Specify the :cursor=>{...} option to override options for the cursor such has :buffer_size=>n.
    # Pass an optional block that takes a Hash of the record and returns what you want to return.
    # For example, return the Hash back to process a Hash instead of a table instance for better speed.
    def find_by_sql_with_cursor(sql, options={})
      PostgreSQLCursor.new(sql, options) { |r| block_given? ? yield(r) : instantiate(r) }
    end

  end
end
