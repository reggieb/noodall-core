module Noodall
  class Node
    include MongoMapper::Document
    include MongoMapper::Acts::Tree
    include Canable::Ables

    plugin MongoMapper::Plugins::MultiParameterAttributes
    plugin Indexer
    plugin Search
    plugin Tagging
    plugin Noodall::GlobalUpdateTime

    key :title, String, :required => true
    key :name, String
    key :description, String
    key :body, String
    key :position, Integer, :default => nil
    key :_type, String
    key :published_at, Time
    key :published_to, Time
    key :updatable_groups, Array
    key :destroyable_groups, Array
    key :publishable_groups, Array
    key :viewable_groups, Array
    key :permalink, Permalink, :required => true, :index => true

    timestamps!
    userstamps!

    alias_method :keywords, :tag_list
    alias_method :keywords=, :tag_list=

    attr_accessor :publish, :hide #for publishing

    acts_as_tree :order => "position", :search_class => Noodall::Node

    # if there are any children that are not of an allowed template, error
    validates_true_for :template,
      :message => "cannot be changed as sub content is not allowed in this template",
      :logic => lambda { children.empty? || children.select{|c| !self._type.constantize.template_classes.include?(c.class)}.empty? }

    scope :published, lambda { where(:published_at => { :$lte => current_time }, :published_to => { :$gte => current_time }) }

    def published_children
      self.children.select{|c| c.published? }
    end

    # Allow parent to be set to none using a string. Allows us to set the parent to nil easily via forms
    def parent=(var)
      self[parent_id_field] = nil
      var == "none" ? super(nil) : super
    end

    def template
      self.class.name.titleize
    end

    def template=(template_name)
      self._type = template_name.gsub(' ','') unless template_name.blank?
    end

    def published?
      !published_at.nil? and published_at <= current_time and (published_to.nil? or published_to >= current_time)
    end

    def pending?
      published_at.nil? or published_at >= current_time
    end

    def expired?
      !published_to.nil? and published_to <= current_time
    end

    def first?
      position == 0
    end

    def last?
      position == search_class.count(:_id => {"$ne" => self._id}, parent_id_field => self[parent_id_field])
    end
    def move_lower
      sibling = search_class.first(:position => {"$gt" => self.position}, parent_id_field => self[parent_id_field], :order => 'position ASC')

      tmp = sibling.position
      sibling.position = self.position
      self.position = tmp

      search_class.collection.update({:_id => self._id}, self.to_mongo)
      search_class.collection.update({:_id => sibling._id}, sibling.to_mongo)

      global_updated!
    end
    def move_higher
      sibling = search_class.first(:position => {"$lt" => self.position}, parent_id_field => self[parent_id_field], :order => 'position DESC')

      tmp = sibling.position
      sibling.position = self.position
      self.position = tmp

      search_class.collection.update({:_id => self._id}, self.to_mongo)
      search_class.collection.update({:_id => sibling._id}, sibling.to_mongo)

      global_updated!
    end

    def run_callbacks(kind, options = {}, &block)
      self.class.send("#{kind}_callback_chain").run(self, options, &block)
      self.embedded_associations.each do |association|
        self.send(association.name).each do |document|
          document.run_callbacks(kind, options, &block)
        end
      end
      self.embedded_keys.each do |key|
        self.send(key.name).run_callbacks(kind, options, &block) unless self.send(key.name).nil?
      end
    end

    def slots
      slots = []
      for slot_type in self.class.possible_slots.map(&:to_s)
        self.class.send("#{slot_type}_slots_count").to_i.times do |i|
          slots << self.send("#{slot_type}_slot_#{i}")
        end
      end
      slots.compact
    end

    ## CANS
    def all_groups
      updatable_groups | destroyable_groups | publishable_groups | viewable_groups
    end

    %w( updatable destroyable publishable viewable ).each do |permission|
      define_method("#{permission}_by?") do |user|
        user.admin? or send("#{permission}_groups").empty? or user.groups.any?{ |g| send("#{permission}_groups").include?(g) }
      end

      define_method("#{permission}_groups_list") do
        send("#{permission}_groups").join(', ')
      end

      define_method("#{permission}_groups_list=") do |groups_string|
        send("#{permission}_groups=", groups_string.downcase.split(',').map{|g| g.blank? ? nil : g.strip }.compact.uniq)
      end
    end

    def creatable_by?(user)
      parent.nil? or parent.updatable_by?(user)
    end

    def siblings
      search_class.where(:_id => {:$ne => self._id}, parent_id_field => self[parent_id_field]).order(tree_order)
    end

    def self_and_siblings
      search_class.where(parent_id_field => self[parent_id_field]).order(tree_order)

    end

    def children
      search_class.where(parent_id_field => self._id).order(tree_order)
    end

    def in_site_map?
      Noodall::Site.contains?(self.permalink.to_s)
    end

  private

    def current_time
      self.class.current_time
    end

    before_validation :set_permalink
    def set_permalink
      if permalink.blank?
        # inherit the parents permalink and append the current node's .name or .title attribute
        # this code takes name over title for the current node's slug
        # this way enables children to inherit the parent's custom (user defined) permalink also
        permalink_args = self.parent.nil? ? [] : self.parent.permalink
        self_slug = (self.name.blank? ? self.title : self.name).to_s.parameterize
        permalink_args << self_slug unless self_slug.blank?
        self.permalink = Permalink.new(*permalink_args)
      end
    end

    before_save :set_position
    def set_position
      write_attribute :position, siblings.size if position.nil?
    end

    before_save :clean_slots

    # This method removes any uneeded modules from the object
    # modules that would otherwise remain hidden
    # if the objects class was changed
    def clean_slots

      # TODO: spec this

      slot_types = self.class.possible_slots.map(&:to_s)
      # collect all of the slot attributes
      #    (so we don't have to loop through the whole object each time)
      slots = self.attributes.select{|k,v| k =~ /^(#{slot_types.join('|')})_slot_\d+$/ }

      # for each type of slot
      for slot_type in slot_types
        # get the number of slots of this type in the (possibly new) class
        slot_count = self._type.constantize.send("#{slot_type}_slots_count").to_i

        # loop through all of the slot attributes for this type
        slots.select{|k,v| k =~ /^#{slot_type}_slot_\d+$/ }.each do |key, slot|

          index = key[/#{slot_type}_slot_(\d+)$/, 1].to_i

          logger.debug "Deleting #{key} #{self.send(key).inspect}" if index >= slot_count
          # set the slot to nil
          write_attribute(key.to_sym, nil) if index >= slot_count
        end
      end
    end

    before_save :set_path
    def set_path
      write_attribute :path, parent.path + [parent._id] unless parent.nil?
    end

    before_create :inherit_permisions
    def inherit_permisions
      unless parent.nil?
        self.updatable_groups  = parent.updatable_groups
        self.destroyable_groups = parent.destroyable_groups
        self.publishable_groups = parent.publishable_groups
        self.viewable_groups = parent.viewable_groups
      end
    end

    after_save :order_siblings
    def order_siblings
      if position_changed?
        search_class.collection.update({:_id => {"$ne" => self._id}, :position => {"$gte" => self.position}, parent_id_field => self[parent_id_field]}, { "$inc" => { :position => 1 }}, { :multi => true })
        self_and_siblings.each_with_index do |sibling, index|
          unless sibling.position == index
            sibling.position = index
            search_class.collection.save(sibling.to_mongo, :safe => true)
          end
        end
      end
    end

    before_save :set_published
    def set_published
      if publish
        write_attribute :published_at, current_time if published_at.nil?
        write_attribute :published_to, 10.years.from_now if published_to.nil?
      end
      if hide
        write_attribute :published_at, nil
        write_attribute :published_to, 10.years.from_now
      end
    end

    before_save :set_name
    def set_name
      self.name = self.title if self.name.blank?
    end

    class << self
      @@slots = []

      # Set the names of the slots that will be avaiable to fill with components
      # For each name new methods will be created;
      #
      #   <name>_slots(count)
      #   This allow you to set the number of slots available in a template
      #   <name>_slots_count(count)
      #   Reads back the count you set
      def slots(*args)
        @@slots = args.map(&:to_sym).uniq

        @@slots.each do |slot|
          puts "Noodall::Node Defined slot: #{slot}"
          define_singleton_method("#{slot}_slots") do |count|
            instance_variable_set("@#{slot}_slots_count", count)
            count.times do |i|
              key "#{slot}_slot_#{i}", Noodall::Component
              validates_each "#{slot}_slot_#{i}", :logic => lambda { errors.add("#{slot}_slot_#{i}", "is not allowed in a #{slot} slot") unless send("#{slot}_slot_#{i}").nil? or Noodall::Component.positions_classes(slot).include?(send("#{slot}_slot_#{i}").class) } # TODO: Nicer message please
              validates_associated "#{slot}_slot_#{i}"
            end
          end
          define_singleton_method("#{slot}_slots_count") { instance_variable_get("@#{slot}_slots_count") }
        end
      end

      def slots_count
        @@slots.inject(0) { |total, slot| total + send("#{slot}_slots_count").to_i }
      end

      def possible_slots
        @@slots
      end

      def roots(options = {})
        self.where(parent_id_field => nil).order(tree_order)
      end

      def find_by_permalink(permalink)
        node = find_one(:permalink => permalink.to_s, :published_at => { :$lte => current_time })
        raise MongoMapper::DocumentNotFound if node.nil? or node.expired?
        node
      end

      def template_classes
        return root_templates if self == Noodall::Node
        @template_classes || []
      end

      def root_templates
        return @root_templates if @root_templates
        classes = []
        ObjectSpace.each_object(Class) do |c|
          next unless c.ancestors.include?(Noodall::Node) and (c != Noodall::Node) and c.root_template?
          classes << c
        end
        @root_templates = classes
      end

      def template_names
        template_classes.collect{|c| c.name.titleize}.sort
      end

      def all_template_classes
        templates = []
        template_classes.each do |template|
          templates << template
          templates = templates + template.template_classes
        end
        templates.uniq.collect{ |c| c.name.titleize }.sort
      end

      def sub_templates(*arr)
        @template_classes = arr
      end

      def root_template!
        @root_template = true
      end

      def root_template?
        @root_template
      end

      # Returns a list of classes that can have this model as a child
      def parent_classes
        classes = []
        ObjectSpace.each_object(Class) do |c|
          next unless c.ancestors.include?(Noodall::Node) and (c != Noodall::Node) and c.template_classes.include?(self)
          classes << c
        end
        classes
      end

      # If rails style time zones are unavaiable fallback to standard now
      def current_time
        Time.zone ? Time.zone.now : Time.now
      end
    end

  end

end
