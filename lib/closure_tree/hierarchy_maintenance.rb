require 'active_support/concern'

module ClosureTree
  module HierarchyMaintenance
    extend ActiveSupport::Concern

    included do
      validate :_ct_validate
      before_save :_ct_before_save
      after_save :_ct_after_save
      before_destroy :_ct_before_destroy
    end

    def _ct_skip_cycle_detection!
      @_ct_skip_cycle_detection = true
    end

    # Set flag and propagate to all children.
    def _ct_fast_insert!(root: true)
      @_ct_fast_insert = true
      @_ct_fast_insert_root = true if root
      children.each { |c| c._ct_fast_insert!(root: false) }
    end

    def _ct_skip_sort_order_maintenance!
      @_ct_skip_sort_order_maintenance = true
    end

    def _ct_validate
      if !(defined? @_ct_skip_cycle_detection) &&
        !new_record? && # don't validate for cycles if we're a new record
        changes[_ct.parent_column_name] && # don't validate for cycles if we didn't change our parent
        parent.present? && # don't validate if we're root
        parent.self_and_ancestors.include?(self) # < this is expensive :\
        errors.add(_ct.parent_column_sym, I18n.t('closure_tree.loop_error', default: 'You cannot add an ancestor as a descendant'))
      end
    end

    def _ct_before_save
      @was_new_record = new_record?
      true # don't cancel the save
    end

    def _ct_after_save
      # If doing a fast insert, we don't run the rest of this method because rebuild! is slow.
      # Additionally, if this is the root of the insert, we initiate a top-down
      # hierarchy node insertion process.
      if @_ct_fast_insert
        return unless @_ct_fast_insert_root
        _ct_fast_insert_hierarchy_nodes
        return
      end

      as_5_1 = ActiveSupport.version >= Gem::Version.new('5.1.0')
      changes_method = as_5_1 ? :saved_changes : :changes

      if public_send(changes_method)[_ct.parent_column_name] || was_new_record?
        rebuild!
      end
      if public_send(changes_method)[_ct.parent_column_name] && !was_new_record?
        # Resetting the ancestral collections addresses
        # https://github.com/mceachen/closure_tree/issues/68
        ancestor_hierarchies.reload
        self_and_ancestors.reload
      end
      @was_new_record = false # we aren't new anymore.
      @_ct_skip_sort_order_maintenance = false # only skip once.
      true # don't cancel anything.
    end

    def _ct_before_destroy
      _ct.with_advisory_lock do
        delete_hierarchy_references
        if _ct.options[:dependent] == :nullify
          self.class.find(self.id).children.find_each { |c| c.rebuild! }
        end
      end
      true # don't prevent destruction
    end

    # Inserts appropriate hierarchy nodes, starting with root.
    def _ct_fast_insert_hierarchy_nodes
      hierarchy_class.create!(:ancestor => self, :descendant => self, :generations => 0)
      unless root?
        _ct.connection.execute <<-SQL.strip_heredoc
          INSERT INTO #{_ct.quoted_hierarchy_table_name}
            (ancestor_id, descendant_id, generations)
          SELECT x.ancestor_id, #{_ct.quote(_ct_id)}, x.generations + 1
          FROM #{_ct.quoted_hierarchy_table_name} x
          WHERE x.descendant_id = #{_ct.quote(_ct_parent_id)}
        SQL
      end
      children.each { |c| c._ct_fast_insert_hierarchy_nodes }
    end

    def rebuild!(called_by_rebuild = false)
      _ct.with_advisory_lock do
        delete_hierarchy_references unless was_new_record?
        hierarchy_class.create!(:ancestor => self, :descendant => self, :generations => 0)
        unless root?
          _ct.connection.execute <<-SQL.strip_heredoc
            INSERT INTO #{_ct.quoted_hierarchy_table_name}
              (ancestor_id, descendant_id, generations)
            SELECT x.ancestor_id, #{_ct.quote(_ct_id)}, x.generations + 1
            FROM #{_ct.quoted_hierarchy_table_name} x
            WHERE x.descendant_id = #{_ct.quote(_ct_parent_id)}
          SQL
        end

        if _ct.order_is_numeric? && !@_ct_skip_sort_order_maintenance
          _ct_reorder_prior_siblings_if_parent_changed
          # Prevent double-reordering of siblings:
          _ct_reorder_siblings if !called_by_rebuild
        end

        children.find_each { |c| c.rebuild!(true) }

        if !was_new_record? && !@_ct_skip_sort_order_maintenance && _ct.order_is_numeric? && children.present?
          _ct_reorder_children
        end
      end
    end

    def delete_hierarchy_references
      _ct.with_advisory_lock do
        # The crazy double-wrapped sub-subselect works around MySQL's limitation of subselects on the same table that is being mutated.
        # It shouldn't affect performance of postgresql.
        # See http://dev.mysql.com/doc/refman/5.0/en/subquery-errors.html
        # Also: PostgreSQL doesn't support INNER JOIN on DELETE, so we can't use that.
        _ct.connection.execute <<-SQL.strip_heredoc
          DELETE FROM #{_ct.quoted_hierarchy_table_name}
          WHERE descendant_id IN (
            SELECT DISTINCT descendant_id
            FROM (SELECT descendant_id
              FROM #{_ct.quoted_hierarchy_table_name}
              WHERE ancestor_id = #{_ct.quote(id)}
                 OR descendant_id = #{_ct.quote(id)}
            ) #{ _ct.t_alias_keyword } x )
        SQL
      end
    end

    def was_new_record?
      (defined? @was_new_record) && @was_new_record
    end

    module ClassMethods
      # Rebuilds the hierarchy table based on the parent_id column in the database.
      # Note that the hierarchy table will be truncated.
      def rebuild!
        _ct.with_advisory_lock do
          hierarchy_class.delete_all # not destroy_all -- we just want a simple truncate.
          roots.find_each { |n| n.send(:rebuild!) } # roots just uses the parent_id column, so this is safe.
        end
        nil
      end
    end
  end
end
