# encoding: utf-8
#
require "logstash/inputs/threadable"
require "logstash/namespace"
require "logstash/timestamp"
require "logstash/plugin_mixins/aws_config"
require "logstash/errors"
require "logstash/inputs/sqs_s3/patch"
require "multiple_files_gzip_reader"

# Forcibly load all modules marked to be lazily loaded.
#
# It is recommended that this is called prior to launching threads. See
# https://aws.amazon.com/blogs/developer/threading-with-the-aws-sdk-for-ruby/.
Aws.eager_autoload!

# Get logs from AWS s3 buckets as issued by an object-created event via sqs.
#
# This plugin is based on the logstash-input-sqs plugin but doesn't log the sqs event itself.
# Instead it assumes, that the event is an s3 object-created event and will then download
# and process the given file.
#
# Some issues of logstash-input-sqs, like logstash not shutting down properly, have been
# fixed for this plugin.
#
# In contrast to logstash-input-sqs this plugin uses the "Receive Message Wait Time"
# configured for the sqs queue in question, a good value will be something like 10 seconds
# to ensure a reasonable shutdown time of logstash.
# Also use a "Default Visibility Timeout" that is high enough for log files to be downloaded
# and processed (I think a good value should be 5-10 minutes for most use cases), the plugin will
# avoid removing the event from the queue if the associated log file couldn't be correctly
# passed to the processing level of logstash (e.g. downloaded content size doesn't match sqs event).
#
# This plugin is meant for high availability setups, in contrast to logstash-input-s3 you can safely
# use multiple logstash nodes, since the usage of sqs will ensure that each logfile is processed
# only once and no file will get lost on node failure or downscaling for auto-scaling groups.
# (You should use a "Message Retention Period" >= 4 days for your sqs to ensure you can survive
# a weekend of faulty log file processing)
# The plugin will not delete objects from s3 buckets, so make sure to have a reasonable "Lifecycle"
# configured for your buckets, which should keep the files at least "Message Retention Period" days.
#
# A typical setup will contain some s3 buckets containing elb, cloudtrail or other log files.
# These will be configured to send object-created events to a sqs queue, which will be configured
# as the source queue for this plugin.
# (The plugin supports gzipped content if it is marked with "contend-encoding: gzip" as it is the
# case for cloudtrail logs)
#
# The logstash node therefore must have sqs permissions + the permissions to download objects
# from the s3 buckets that send events to the queue.
# (If logstash nodes are running on EC2 you should use a ServerRole to provide permissions)
# [source,json]
#   {
#       "Version": "2012-10-17",
#       "Statement": [
#           {
#               "Effect": "Allow",
#               "Action": [
#                   "sqs:Get*",
#                   "sqs:List*",
#                   "sqs:ReceiveMessage",
#                   "sqs:ChangeMessageVisibility*",
#                   "sqs:DeleteMessage*"
#               ],
#               "Resource": [
#                   "arn:aws:sqs:us-east-1:123456789012:my-elb-log-queue"
#               ]
#           },
#           {
#               "Effect": "Allow",
#               "Action": [
#                   "s3:Get*",
#                   "s3:List*"
#               ],
#               "Resource": [
#                   "arn:aws:s3:::my-elb-logs",
#                   "arn:aws:s3:::my-elb-logs/*"
#               ]
#           }
#       ]
#   }
#
class LogStash::Inputs::SQSS3 < LogStash::Inputs::Threadable
  include LogStash::PluginMixins::AwsConfig::V2

  BACKOFF_SLEEP_TIME = 1
  BACKOFF_FACTOR = 2
  MAX_TIME_BEFORE_GIVING_UP = 60
  EVENT_SOURCE = 'aws:s3'
  EVENT_TYPE = 'ObjectCreated'
  MAX_MESSAGES_TO_FETCH = 10 # Between 1-10 in the AWS-SDK doc
  SENT_TIMESTAMP = "SentTimestamp"
  SQS_ATTRIBUTES = [SENT_TIMESTAMP]
  SKIP_DELETE = false

  config_name "sqs_s3"

  default :codec, "plain"

  # Name of the SQS Queue to pull messages from. Note that this is just the name of the queue, not the URL or ARN.
  config :queue, :validate => :string, :required => true

  # Name of the event field in which to store the SQS Receipt Handle
  config :receipt_handle, :validate => :string

  # Name of the event field in which to store the SQS Message Id
  config :message_id, :validate => :string

  # Name of the event field in which to store the SQS message Sent Timestamp
  config :sent_timestamp_field, :validate => :string

  # Max messages to fetch, default is 10
  config :max_messages_to_fetch, :validate => :number, :default => MAX_MESSAGES_TO_FETCH

  # If set to true, does NOT delete the message after polling
  config :skip_delete, :validate => :string, :default => SKIP_DELETE 

  # This is the max current load to support before throttling back (in Bytes)
  config :max_load_before_throttling, :validate => :number, :default => 300000000

  # Number of seconds to throttle back once max load has been met
  config :seconds_to_throttle, :validate => :number, :default => 15

  attr_reader :poller
  attr_reader :s3

  def register
    require "aws-sdk"
    @logger.info("Registering SQS input", :queue => @queue)
    @logger.info("Skip Delete", :skip_delete => @skip_delete)
    @current_load = 0.0
    @jsonCodec = LogStash::Codecs::JSON.new
    @plainCodec = LogStash::Codecs::Plain.new
    setup_queue
  end

  def setup_queue
    aws_sqs_client = Aws::SQS::Client.new(aws_options_hash)
    queue_url = aws_sqs_client.get_queue_url(:queue_name =>  @queue)[:queue_url]
    @poller = Aws::SQS::QueuePoller.new(queue_url, :client => aws_sqs_client)
    @s3 = Aws::S3::Client.new(aws_options_hash)
  rescue Aws::SQS::Errors::ServiceError => e
    @logger.error("Cannot establish connection to Amazon SQS", :error => e)
    raise LogStash::ConfigurationError, "Verify the SQS queue name and your credentials"
  end

  def polling_options
    {
      # the number of messages to fetch in a single api call
      :max_number_of_messages => MAX_MESSAGES_TO_FETCH,
      :attribute_names => SQS_ATTRIBUTES,
      # we will use the queue's setting, a good value is 10 seconds
      # (to ensure fast logstash shutdown on the one hand and few api calls on the other hand)
      :wait_time_seconds => nil,
      :skip_delete => @skip_delete
    }
  end

  def handle_message(message, queue)
    hash = JSON.parse message.body
    # there may be test events sent from the s3 bucket which won't contain a Records array,
    # we will skip those events and remove them from queue
    if hash['Records'] then
      # typically there will be only 1 record per event, but since it is an array we will
      # treat it as if there could be more records
      hash['Records'].each do |record|
        # in case there are any events with Records that aren't s3 object-created events and can't therefore be
        # processed by this plugin, we will skip them and remove them from queue
        if record['eventSource'] == EVENT_SOURCE and record['eventName'].start_with?(EVENT_TYPE) then
          # try download and :skip_delete if it fails
          begin
            response = @s3.get_object(
              bucket: record['s3']['bucket']['name'],
              key: record['s3']['object']['key']
            )
          rescue => e
            @logger.warn("issuing :skip_delete on failed download", :bucket => record['s3']['bucket']['name'], :object => record['s3']['object']['key'], :error => e)
            throw :skip_delete
          end
          # verify downloaded content size
          if response.content_length == record['s3']['object']['size'] then
            body = response.body
            # if necessary unzip. Note: Firehose is automatically gzipped but does NOT include the content encoding or the extension.
            if response.content_encoding == "gzip" or record['s3']['object']['key'].end_with?(".gz") or record['s3']['object']['key'].include?("/firehose/") then
              begin
	        temp = MultipleFilesGzipReader.new(body)
              rescue => e
                @logger.warn("content is marked to be gzipped but can't unzip it, assuming plain text", :bucket => record['s3']['bucket']['name'], :object => record['s3']['object']['key'], :error => e)
                temp = body
              end
              body = temp
            end
            # process the plain text content
            begin
	      # assess currently running load (in MB)
              @current_load += (record['s3']['object']['size'].to_f / 1000000)

	      if record['s3']['object']['key'].include?("/firehose/") then
                 lines = body.read.encode('UTF-8', 'binary').gsub("}{", "}\n{").split(/\n/)
              else
                 lines = body.read.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: "\u2370").split(/\n/)
              end

	      # Set the codec to json if required, otherwise the default is plain text. Firehose is always in JSON format
              if response.content_type == "application/json" or record['s3']['object']['key'].include?("/firehose/") then
                @codec = @jsonCodec
		
		if response.content_encoding != "gzip" then
		  # If it's json in plain text, need to remove whitespaces
		  # TODO...
		end
              else
                @codec = @plainCodec
		#lines = lines.split(/\n/)
              end

              lines.each do |line|
                @codec.decode(line) do |event|
                  decorate(event)

                  event.set('[@metadata][s3_bucket_name]', record['s3']['bucket']['name'])
                  event.set('[@metadata][s3_object_key]', record['s3']['object']['key'])
		  event.set('[@metadata][event_type]', 's3')
		  event.set('[@metadata][s3_object_encoding]', response.content_encoding)
                  event.set('[@metadata][s3_object_type]', response.content_type)

                  queue << event
                end
              end

	      event = LogStash::Event.new()
              event.set('[@metadata][event_type]', 'complete')
	      event.set('[@metadata][' + @receipt_handle + ']', message.receipt_handle) if @receipt_handle
              event.set('[@metadata][' + @message_id + ']', message.message_id) if @message_id
	      event.set('[@metadata][s3_object_key]', record['s3']['object']['key'])
              event.set('[@metadata][' + @sent_timestamp_field + ']', convert_epoch_to_timestamp(message.attributes[SENT_TIMESTAMP])) if @sent_timestamp_field

	      queue << event
            rescue => e
              @logger.warn("issuing :skip_delete on failed plain text processing", :bucket => record['s3']['bucket']['name'], :object => record['s3']['object']['key'], :error => e)
              throw :skip_delete
            end
          # otherwise try again later
          else
            @logger.warn("issuing :skip_delete on wrong download content size", :bucket => record['s3']['bucket']['name'], :object => record['s3']['object']['key'],
              :download_size => response.content_length, :expected => record['s3']['object']['size'])
            throw :skip_delete
          end
        end
      end
    end
  end

  def run(queue)
    # ensure we can stop logstash correctly
    poller.before_request do |stats|
      if stop? then
        @logger.warn("issuing :stop_polling on stop?", :queue => @queue)
        # this can take up to "Receive Message Wait Time" (of the sqs queue) seconds to be recognized
        throw :stop_polling
      end

      # Throttle requests is overloaded by big files
      if @current_load > @max_load_before_throttling/1000000 then
	throttle_seconds_sleep = @seconds_to_throttle * (@current_load / (@max_load_before_throttling.to_f/1000000)).floor
        @logger.warn("**********Current load has exceeded " + (@max_load_before_throttling.to_f/1000000).to_s + " MB. Load is currently: " + @current_load.to_s + ". Throttling back by " + throttle_seconds_sleep.to_s)

	# Cap the throttle time to 1 min
        if(throttle_seconds_sleep != 0) then
	  if(throttle_seconds_sleep > 60) then
            sleep(60)
	  else
	    sleep(throttle_seconds_sleep)
          end
        end
      end

      # Reset load to 0
      @current_load = 0.0
    end
    # poll a message and process it
    run_with_backoff do
      poller.poll(polling_options) do |messages|
        messages.each do |message|
          handle_message(message, queue)
	end
      end
    end
  end

  private
  # Runs an AWS request inside a Ruby block with an exponential backoff in case
  # we experience a ServiceError.
  #
  # @param [Integer] max_time maximum amount of time to sleep before giving up.
  # @param [Integer] sleep_time the initial amount of time to sleep before retrying.
  # @param [Block] block Ruby code block to execute.
  def run_with_backoff(max_time = MAX_TIME_BEFORE_GIVING_UP, sleep_time = BACKOFF_SLEEP_TIME, &block)
    next_sleep = sleep_time
    begin
      block.call
      next_sleep = sleep_time
    rescue Aws::SQS::Errors::ServiceError => e
      @logger.warn("Aws::SQS::Errors::ServiceError ... retrying SQS request with exponential backoff", :queue => @queue, :sleep_time => sleep_time, :error => e)
      sleep(next_sleep)
      next_sleep =  next_sleep > max_time ? sleep_time : sleep_time * BACKOFF_FACTOR
      retry
    end
  end

  def convert_epoch_to_timestamp(time)
    LogStash::Timestamp.at(time.to_i / 1000)
  end
end # class
