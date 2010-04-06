require 'openssl'
require 'base64'

module Paperclip
  module Storage        
    
    module Appengine      
      begin
        require 'rest_client'              
      rescue LoadError => e
        e.message << " (You may need to install the rest-client gem)"
        raise e
      end

      # RestClient.log = RAILS_DEFAULT_LOGGER

      METHOD_OVERRIDE_HEADER = 'X-HTTP-Method-Override'
      
      def self.extended base    
        attr_accessor :image_hosting_engine
        
        base.instance_eval do
          @config = parse_credentials(@options[:appengine_config])
          @url            = ":pse_url" 
          @path           = ":pse_path" 
        end

        Paperclip.interpolates(:pse_url) do |attachment, style|                                        
          attachment.attachment_url(style, attachment.original_filename)
        end
        
        Paperclip.interpolates(:pse_path) do |attachment, style|                                        
          attachment.pse_attachment_id(style)
        end
        
      end      

      def parse_credentials creds
        creds = find_credentials(creds).stringify_keys
        (creds[RAILS_ENV] || creds).symbolize_keys
      end  
      

      
      def exists?(style = default_style)
        if original_filename                    
          begin
            RestClient::Request.execute(:method => :head, :url => attachment_url(style)).code == 200
          rescue RestClient::ResourceNotFound => e
            false
          end          
        else
          false
        end
      end

      # Returns representation of the data of the file assigned to the given
      # style, in the format most representative of the current storage.
      def to_file style = default_style       
        return @queued_for_write[style] if @queued_for_write[style]
        file = Tempfile.new(path(style))
        file.write(RestClient.get(attachment_url(style)).body)
        file.rewind
        return file
      end

      def flush_writes #:nodoc:
        @queued_for_write.each do |style, file|
          begin         
            # next unless style == 'original'
            # debugger
            log("saving '#{style}' -> #{path(style)}")
            client.post(:data => file, 
              :attachment_id => pse_attachment_id(style), 
              :content_type => instance_read(:content_type))          
          rescue  => e
            raise e
          end
        end
        @queued_for_write = {}
      end

      def flush_deletes #:nodoc:
        @queued_for_delete.each do |path|
          begin
            log("deleting -> #{path}")  
            client.post({:attachment_id => path}, 
               {METHOD_OVERRIDE_HEADER => "DELETE"})        
          rescue 
            # Ignore this.
          end
        end
        @queued_for_delete = []
      end 
           
      

            
      def attachment_url(style, filename = nil) 
         File.join(pse_url, pse_attachment_id(style), filename.to_s)
      end
            
      def pse_url
        @config[:url] || "http://#{@config[:app_id]}.appspot.com"    
      end      

      def pse_attachment_id(style = default_style)
        "#{@instance.class.name.underscore}_#{@name}_#{@instance.id}_#{style}"
      end
      
          
      private   
      
      def client
        token, signature = generate_auth                      
        @resource = RestClient::Resource.new(pse_url, {:user => token, :password => signature})        
      end
      
      
      def generate_auth
        token = OpenSSL::Digest::Digest.new('sha256', OpenSSL::Random::random_bytes(128)).hexdigest()    
        [token, OpenSSL::HMAC.hexdigest(OpenSSL::Digest::Digest.new('sha256'), @config[:shared_secret], token)]
      end

      
      def find_credentials creds
        case creds
        when File
          YAML::load(ERB.new(File.read(creds.path)).result)
        when String
          YAML::load(ERB.new(File.read(creds)).result)
        when Hash
          creds
        else
          raise ArgumentError, "Credentials are not a path, file, or hash."
        end
      end
      private :find_credentials
    end
  end
end