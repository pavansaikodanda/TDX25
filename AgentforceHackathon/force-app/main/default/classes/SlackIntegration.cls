/**
 * SlackIntegration
 * 
 * Apex class that provides an invocable method to send messages to Slack
 * from Salesforce Flow, Process Builder, or Apex code.
 * Uses custom settings for Slack configuration.
 */
public with sharing class SlackIntegration {
    // Constants
    private static final String SLACK_API_URL = 'https://slack.com/api/chat.postMessage';
    private static final String SLACK_CONVERSATIONS_URL = 'https://slack.com/api/conversations.list';
    private static final String DEFAULT_CHANNEL = 'C08Q8L2204U';
    private static final Integer MAX_BATCH_SIZE = 100;
    
    // Retrieve token from custom setting instead of hardcoding
    private static String getSlackToken() {
        // In production, this should be retrieved from a Custom Setting or Named Credential
        // For demonstration purposes only - in real implementation this should NOT be hardcoded
        return null;
    }
    
    /**
     * Invocable method to send a message to Slack channels
     * Auto-discovers available channels and sends to all or specific channels
     * Always retrieves fresh channel list when auto-discovery is enabled
     * @param requests List of SlackRequest objects containing message details
     * @return List of SlackResult objects with the results of each operation
     */
    @InvocableMethod(label='Send Message to Slack' description='Sends a message to Slack channels with auto-discovery')
    public static List<SlackResult> sendMessageToSlack(List<SlackRequest> requests) {
        // Validate input
        if (requests == null || requests.isEmpty()) {
            throw new SlackIntegrationException('No requests provided');
        }
        
        // Check batch size to prevent hitting governor limits
        if (requests.size() > MAX_BATCH_SIZE) {
            throw new SlackIntegrationException('Batch size exceeds maximum of ' + MAX_BATCH_SIZE);
        }
        
        List<SlackResult> results = new List<SlackResult>();
        
        for (SlackRequest req : requests) {
            List<SlackResult> requestResults = new List<SlackResult>();
            
            try {
                // Validate required fields
                if (String.isBlank(req.message)) {
                    throw new SlackIntegrationException('Message is required');
                }
                
                // Process primary channel and additional channels
                List<String> targetChannels = new List<String>();
                
                // If sendToAllChannels is true, get all available channels fresh every time
                if (req.sendToAllChannels) {
                    try {
                        System.debug(LoggingLevel.INFO, 'Auto-discovering Slack channels...');
                        List<SlackChannel> channels = getSlackChannels();
                        System.debug(LoggingLevel.INFO, 'Found ' + channels.size() + ' channels');
                        
                        for (SlackChannel channel : channels) {
                            targetChannels.add(channel.id);
                            System.debug(LoggingLevel.FINE, 'Adding channel: ' + channel.name + ' (' + channel.id + ')');
                        }
                    } catch (Exception e) {
                        System.debug(LoggingLevel.ERROR, 'Error getting channels: ' + e.getMessage());
                        throw new SlackIntegrationException('Error getting channels: ' + e.getMessage());
                    }
                } else {
                    // Add primary channel if specified, otherwise use default
                    String primaryChannel = String.isNotBlank(req.channel) ? req.channel : DEFAULT_CHANNEL;
                    targetChannels.add(primaryChannel);
                    
                    // Add additional channels if specified
                    if (req.additionalChannels != null && !req.additionalChannels.isEmpty()) {
                        targetChannels.addAll(req.additionalChannels);
                    }
                }
                
                // Make sure we have at least one channel
                if (targetChannels.isEmpty()) {
                    throw new SlackIntegrationException('No channels specified and unable to discover channels');
                }
                
                System.debug(LoggingLevel.INFO, 'Sending message to ' + targetChannels.size() + ' channels');
                
                // Send to each channel
                for (String channelId : targetChannels) {
                    if (String.isNotBlank(channelId)) {
                        SlackResult channelResult = sendToSingleChannel(req, channelId);
                        requestResults.add(channelResult);
                    }
                }
                
                // Aggregate results
                SlackResult aggregateResult = aggregateResults(requestResults);
                results.add(aggregateResult);
                
            } catch (Exception e) {
                SlackResult errorResult = new SlackResult();
                errorResult.success = false;
                errorResult.response = 'Error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, 'SlackIntegration error: ' + e.getMessage() + '\n' + e.getStackTraceString());
                results.add(errorResult);
            }
        }
        
        return results;
    }
    
    /**
     * Sends a message to a single Slack channel
     * @param req The SlackRequest object
     * @param channelId The channel to send the message to
     * @return SlackResult containing the result of the operation
     */
    private static SlackResult sendToSingleChannel(SlackRequest req, String channelId) {
        SlackResult result = new SlackResult();
        
        try {
            // Prepare the request body
            Map<String, Object> bodyMap = prepareRequestBody(req, channelId);
            
            // Send to Slack and get response
            String responseBody = sendHttpRequest(JSON.serialize(bodyMap));
            
            // Parse response
            Map<String, Object> responseMap = parseSlackResponse(responseBody);
            Boolean isSuccess = (Boolean)responseMap.get('ok');
            
            // Set result
            result.success = isSuccess;
            result.response = responseBody;
            result.channel = channelId;
            
            if (!isSuccess) {
                System.debug(LoggingLevel.ERROR, 'Slack API error for channel ' + channelId + ': ' + responseMap.get('error'));
            }
        } catch (Exception e) {
            result.success = false;
            result.response = 'Error sending to channel ' + channelId + ': ' + e.getMessage();
            result.channel = channelId;
            System.debug(LoggingLevel.ERROR, 'SlackIntegration error for channel ' + channelId + ': ' + e.getMessage());
        }
        
        return result;
    }
    
    /**
     * Aggregates results from multiple channel sends into a single result
     * @param channelResults List of results from individual channel sends
     * @return SlackResult with aggregated information
     */
    private static SlackResult aggregateResults(List<SlackResult> channelResults) {
        SlackResult aggregateResult = new SlackResult();
        
        // Default to success
        aggregateResult.success = true;
        
        // Check if any channel send failed
        List<String> responseDetails = new List<String>();
        List<String> successChannels = new List<String>();
        List<String> failedChannels = new List<String>();
        
        for (SlackResult result : channelResults) {
            responseDetails.add('Channel ' + result.channel + ': ' + (result.success ? 'Success' : 'Failed'));
            
            if (result.success) {
                successChannels.add(result.channel);
            } else {
                failedChannels.add(result.channel);
                aggregateResult.success = false; // Mark as failed if any channel failed
            }
        }
        
        // Build aggregate response
        aggregateResult.response = 'Successful channels: ' + String.join(successChannels, ', ') + 
                                 '. Failed channels: ' + (failedChannels.isEmpty() ? 'None' : String.join(failedChannels, ', '));
        aggregateResult.channelResults = channelResults;
        
        return aggregateResult;
    }
    
    /**
     * Prepares the request body map based on the request parameters
     * @param req The SlackRequest object
     * @param channelId The channel to send the message to
     * @return Map<String, Object> containing the prepared request body
     */
    private static Map<String, Object> prepareRequestBody(SlackRequest req, String channelId) {
        Map<String, Object> bodyMap = new Map<String, Object>{
            'channel' => channelId,
            'text' => req.message
        };
        
        // Add blocks for rich formatting if specified
        if (String.isNotBlank(req.blocks)) {
            try {
                Object blocksObj = JSON.deserializeUntyped(req.blocks);
                bodyMap.put('blocks', blocksObj);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Error parsing blocks JSON: ' + e.getMessage());
                throw new SlackIntegrationException('Invalid blocks JSON: ' + e.getMessage());
            }
        }
        
        // Add attachments if specified
        if (String.isNotBlank(req.attachments)) {
            try {
                Object attachmentsObj = JSON.deserializeUntyped(req.attachments);
                bodyMap.put('attachments', attachmentsObj);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Error parsing attachments JSON: ' + e.getMessage());
                throw new SlackIntegrationException('Invalid attachments JSON: ' + e.getMessage());
            }
        }
        
        return bodyMap;
    }
    
    /**
     * Sends an HTTP request to the Slack API
     * @param jsonBody The JSON body to send
     * @return String containing the API response
     */
    private static String sendHttpRequest(String jsonBody) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(SLACK_API_URL);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Authorization', 'Bearer ' + getSlackToken());
        request.setBody(jsonBody);
        
        HttpResponse response = http.send(request);
        system.debug('body'+response.getBody());
        // Handle HTTP errors
        if (response.getStatusCode() != 200) {
            throw new SlackIntegrationException('HTTP Error: ' + response.getStatusCode() + ' ' + response.getStatus());
        }
        
        return response.getBody();
    }
    
    /**
     * Parses the Slack API response
     * @param responseBody The response body from Slack API
     * @return Map<String, Object> containing the parsed response
     */
    private static Map<String, Object> parseSlackResponse(String responseBody) {
        try {
            return (Map<String, Object>)JSON.deserializeUntyped(responseBody);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error parsing Slack response: ' + e.getMessage());
            throw new SlackIntegrationException('Invalid response from Slack API: ' + e.getMessage());
        }
    }
    
    /**
     * Channel class to represent a Slack channel
     */
    public class SlackChannel {
        @AuraEnabled
        public String id;
        
        @AuraEnabled
        public String name;
        
        @AuraEnabled
        public Boolean isPrivate;
        
        public SlackChannel(String id, String name, Boolean isPrivate) {
            this.id = id;
            this.name = name;
            this.isPrivate = isPrivate;
        }
    }
    
    /**
     * Class for channel output from invocable method
     */
    public class ChannelOutput {
        @InvocableVariable(label='Channel ID' description='The Slack channel ID')
        public String id;
        
        @InvocableVariable(label='Channel Name' description='The Slack channel name')
        public String name;
        
        @InvocableVariable(label='Is Private' description='Whether the channel is private')
        public Boolean isPrivate;
    }  
    /**
     * Gets all available Slack channels
     * @return List of SlackChannel objects
     */
    public static List<SlackChannel> getSlackChannels() {
        List<SlackChannel> channels = new List<SlackChannel>();
        
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(SLACK_CONVERSATIONS_URL + '?types=public_channel,private_channel');
        request.setMethod('GET');
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        request.setHeader('Authorization', 'Bearer ' + getSlackToken());
        
        try {
            HttpResponse response = http.send(request);
            system.debug('BODYresponse'+response.getBody());
            if (response.getStatusCode() == 200) {
                Map<String, Object> responseMap = parseSlackResponse(response.getBody());
                
                if ((Boolean)responseMap.get('ok')) {
                    List<Object> channelList = (List<Object>)responseMap.get('channels');
                    
                    for (Object obj : channelList) {
                        Map<String, Object> channelMap = (Map<String, Object>)obj;
                        String id = String.valueOf(channelMap.get('id'));
                        String name = String.valueOf(channelMap.get('name'));
                        Boolean isPrivate = Boolean.valueOf(String.valueOf(channelMap.get('is_private')));
                        
                        channels.add(new SlackChannel(id, name, isPrivate));
                    }
                } else {
                    String error = String.valueOf(responseMap.get('error'));
                    System.debug(LoggingLevel.ERROR, 'Slack API error: ' + error);
                    throw new SlackIntegrationException('Failed to get channels: ' + error);
                }
            } else {
                throw new SlackIntegrationException('HTTP Error: ' + response.getStatusCode() + ' ' + response.getStatus());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in getSlackChannels: ' + e.getMessage());
            throw new SlackIntegrationException('Error getting channels: ' + e.getMessage());
        }
        
        return channels;
    }

    
    /**
     * Combined class for all Slack message requests
     * Supports both simple and rich messages
     */
    public class SlackRequest {
        @InvocableVariable(label='Channel' description='Primary Slack channel ID (optional, uses default if blank)')
        public String channel;
        
        @InvocableVariable(label='Additional Channels' description='List of additional channel IDs to send the message to')
        public List<String> additionalChannels;
        
        @InvocableVariable(label='Send To All Channels' description='Whether to automatically discover and send to all channels')
        public Boolean sendToAllChannels = false;
        
        @InvocableVariable(label='Message' description='Message text to send' required=true)
        public String message;
        
        @InvocableVariable(label='Blocks JSON' description='JSON string for Slack blocks (optional)')
        public String blocks;
        
        @InvocableVariable(label='Attachments JSON' description='JSON string for Slack attachments (optional)')
        public String attachments;
    }
    
    /**
     * Inner class for Slack API response
     */
    public class SlackResult {
        @InvocableVariable(label='Success' description='Whether the API call was successful')
        public Boolean success;
        
        @InvocableVariable(label='Response' description='Response from Slack API')
        public String response;
        
        @InvocableVariable(label='Channel' description='The channel this result is for')
        public String channel;
        
        @InvocableVariable(label='Channel Results' description='Results from individual channel sends when multiple channels were targeted')
        public List<SlackResult> channelResults;
    }
    
    /**
     * Custom exception class
     */
    public class SlackIntegrationException extends Exception {}
    
    /**
     * Test method with specified channel
     * @param channel The channel to send to
     * @param message The message to send
     */
    public static void testSlackIntegration(String channel, String message) {
        SlackRequest req = new SlackRequest();
        req.channel = channel;
        req.message = message;
        
        List<SlackRequest> requests = new List<SlackRequest>{req};
        List<SlackResult> results = sendMessageToSlack(requests);
        
        logResults(results);
    }
    
    /**
     * Test method for sending to multiple channels
     * @param primaryChannel The primary channel ID
     * @param additionalChannels List of additional channel IDs
     * @param message The message to send
     */
    public static void testMultiChannelSlackIntegration(String primaryChannel, List<String> additionalChannels, String message) {
        SlackRequest req = new SlackRequest();
        req.channel = primaryChannel;
        req.additionalChannels = additionalChannels;
        req.message = message;
        
        List<SlackRequest> requests = new List<SlackRequest>{req};
        List<SlackResult> results = sendMessageToSlack(requests);
        
        logDetailedResults(results);
    }
    
    /**
     * Test method for rich messages with blocks
     * @param message The message to send
     * @param blocksJson The blocks JSON
     */
    public static void testRichSlackMessage(String message, String blocksJson) {
        SlackRequest req = new SlackRequest();
        req.channel = null; // Use default
        req.message = message;
        req.blocks = blocksJson;
        
        List<SlackRequest> requests = new List<SlackRequest>{req};
        List<SlackResult> results = sendMessageToSlack(requests);
        
        logResults(results);
    }
    
    /**
     * Test method for rich messages sent to multiple channels
     * @param primaryChannel The primary channel ID
     * @param additionalChannels List of additional channel IDs
     * @param message The message to send
     * @param blocksJson The blocks JSON
     */
    public static void testMultiChannelRichSlackMessage(String primaryChannel, List<String> additionalChannels, 
                                                       String message, String blocksJson) {
        SlackRequest req = new SlackRequest();
        req.channel = primaryChannel;
        req.additionalChannels = additionalChannels;
        req.message = message;
        req.blocks = blocksJson;
        
        List<SlackRequest> requests = new List<SlackRequest>{req};
        List<SlackResult> results = sendMessageToSlack(requests);
        
        logDetailedResults(results);
    }
    
    /**
     * Helper method to log basic results of test methods
     * @param results The results to log
     */
    private static void logResults(List<SlackResult> results) {
        for (SlackResult result : results) {
            System.debug('Success: ' + result.success);
            System.debug('Response: ' + result.response);
        }
    }
    
    /**
     * Helper method to log detailed results including individual channel results
     * @param results The results to log
     */
    private static void logDetailedResults(List<SlackResult> results) {
        for (SlackResult result : results) {
            System.debug('Overall Success: ' + result.success);
            System.debug('Overall Response: ' + result.response);
            
            if (result.channelResults != null && !result.channelResults.isEmpty()) {
                System.debug('---- Individual Channel Results ----');
                for (SlackResult channelResult : result.channelResults) {
                    System.debug('Channel: ' + channelResult.channel);
                    System.debug('Success: ' + channelResult.success);
                    System.debug('Response: ' + channelResult.response);
                }
            }
        }
    }
}