require File.expand_path '../redis', File.dirname(__FILE__)
require_relative 'reader'
require_relative 'sender'

class Redis
  
  # Use to respond with raw protocol
  #  Response["+",data,"\n\r"]
  #  Response::OK
  #  Response[]
  class Response < Array
    OK = self["+OK\r\n".freeze].freeze
    PONG = self["+PONG\r\n".freeze].freeze
    NIL_MB = self["*-1\r\n".freeze].freeze
    QUEUED = self["+QUEUED\r\n".freeze].freeze
  end

  class Watcher
    include Deferrable
    
    attr_reader :bound
    
    def initialize
      @watched = []
      @bound = true
      errback { unbind }
      callback { unbind }
    end
    
    def bind database, *keys
      return unless @bound
      keys.each do |key|
        entry = [database, key]
        next if @watched.include? entry
        @watched << entry
        (database.watchers[key] ||= []).push self
      end
    end
    
    def unbind
      return unless @bound
      @watched.each do |database, key|
        key_df_list = database.watchers[key]
        next unless key_df_list
        key_df_list.delete_if { |e| e == self }
      end
      @bound = false
    end
    
  end
  
  module Protocol
    
    include Sender

    # Typically raised by redis_QUIT
    class CloseConnection < Exception
    end
  
    def initialize *args
      @reader = Reader.new
      @multi = nil
      @deferred = nil
      @watcher = nil
      super
    end
    
    def unbind
      @deferred.unbind if @deferred
      @watcher.unbind if @watcher
    end
    
    # Companion to send_data.
    def send_redis data
      if Deferrable === data
        @deferred.unbind if @deferred and @deferred != data
        @deferred = data
      elsif Response === data
        data.each do |item|
          write item
        end
      elsif Integer === data
        write ":#{data}\r\n"
      else
        super
      end
    end
    
    def redis_WATCH *keys
      @watcher ||= Watcher.new
      @watcher.bind @database, *keys
      Response::OK
    end
    
    def redis_UNWATCH
      if @watcher
        @watcher.unbind
        @watcher = nil
      end
      Response::OK
    end

    def redis_MULTI
      raise 'MULTI nesting not allowed' if @multi
      @multi = []
      Response::OK
    end
    
    def redis_DISCARD
      redis_UNWATCH
      @multi = nil
      Response::OK
    end

    def redis_EXEC
      if @watcher
        still_bound = @watcher.bound
        redis_UNWATCH
        unless still_bound
          @multi = nil
          return Response::NIL_MB 
        end
      end
      write "*#{@multi.size}\r\n"
      response = []
      @multi.each do |strings| 
        result = call_redis *strings
        if Deferrable === result
          result.unbind
          send_redis nil
        else
          send_redis result
        end
      end
      @multi = nil
      Response[]
    end
    
    def call_redis command, *arguments
      send "redis_#{command.upcase}", *arguments
    rescue Exception => e
      raise e if CloseConnection === e
      # Redis.logger.warn "#{command.dump}: #{e.class}:/#{e.backtrace[0]} #{e.message}"
      # e.backtrace[1..-1].each {|bt|Redis.logger.warn bt}
      Response["-ERR #{e.class.name}: #{e.message}\r\n" ]
    end
  
    # Process incoming redis protocol
    def on_read data
      @reader.feed data
      until (strings = @reader.gets) == false
        # Redis.logger.warn "#{strings.collect{|a|a.dump}.join ' '}"
        if @multi and !%w{MULTI EXEC DEBUG DISCARD}.include?(strings[0].upcase)
          @multi << strings
          send_redis Response::QUEUED
        else
          send_redis call_redis *strings
        end
      end
    rescue Exception => e
      if CloseConnection === e
        output_buffer_size.zero? ? close : should_close_after_writing
      else
        write "-ERR #{e.class.name}: #{e.message}\r\n" 
      end
    end

  end
end
